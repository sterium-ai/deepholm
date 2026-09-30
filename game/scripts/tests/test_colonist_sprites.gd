extends SceneTree

## colonist_sprites.gd's tile-glide interpolation and
## feet-anchored, direction-aware animation, driven directly against a
## WorldState -- no scene, no running frame loop. Mirrors
## test_colonist_panel_toil.gd's pattern of reaching into WorldState's private
## fields to set up a minimal colonist without ticking a full simulation.
##
## godot --headless --path game --script res://scripts/tests/test_colonist_sprites.gd
## godot --path game --script res://scripts/tests/test_colonist_sprites.gd -- --capture

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const TickDriverType = preload("res://scripts/viewer/tick_driver.gd")
const Boot = preload("res://scripts/boot.gd")

const TILE_SIZE := 16.0
## Read the real constant instead of duplicating its
## formula, so a colonist-scale correction in colonist_sprites.gd can never
## silently drift out of sync with what this test asserts against.
const SPRITE_POSITION_OFFSET := ColonistSpritesType.SPRITE_POSITION_OFFSET
const EVIDENCE_DIR := "user://captures"

## Route-glide measurement constants: FRAME_DELTA mirrors a 60fps
## _process() call; MAX_ROUTE_TICKS bounds the drive loop against a genuinely
## stuck colonist (environment issue) instead of looping forever;
## DISPLACEMENT_EPSILON distinguishes a real sub-pixel glide step from the
## "frozen" pause a per-tile stutter would produce; DISPLACEMENT_TOLERANCE_PX
## is the required "+/-1px of the route's constant pace" bound.
const FRAME_DELTA := 1.0 / 60.0
const MAX_ROUTE_TICKS := 300
const DISPLACEMENT_EPSILON := 0.0001
const DISPLACEMENT_TOLERANCE_PX := 1.0

var _failed := false

func _init() -> void:
	if "--measure" in OS.get_cmdline_user_args():
		_print_measurement_table()
		return

	_check_glide(0, 1, "down", false, "moving down")
	_check_glide(0, -1, "up", false, "moving up")
	_check_glide(1, 0, "side", false, "moving right")
	_check_glide(-1, 0, "side", true, "moving left (flipped)")
	_check_snap_on_large_jump()
	_check_snap_on_spawn()
	_check_paused_freezes_t()
	_check_snap_on_new_game()
	_check_trapped_marker_visibility()
	_check_constant_glide_across_straight_route()
	_check_l_shaped_route_has_no_pause_at_corner()

	if _failed:
		quit(1)
		return
	print("test_colonist_sprites: PASS")
	if "--capture" in OS.get_cmdline_user_args():
		_capture_evidence.call_deferred()
		return
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _build_world(colonist_x: int, colonist_y: int) -> WorldStateType:
	var world := WorldStateType.new(1, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({
		"id": "colonist_0", "kind": "colonist", "x": colonist_x, "y": colonist_y,
		"route": null, "work": null, "carrying": null,
	})
	return world

func _driver_at(world: WorldStateType, speed: int) -> TickDriverType:
	var driver := TickDriverType.new(world)
	driver.set_speed(speed)
	return driver

## Moves the single colonist by exactly one orthogonal tile and asserts the
## interpolated pixel position at t=0, t=0.5 and t=1, plus the resulting
## animation name/flip_h -- covering at least one down, one up, and one side
## (including a flipped-left) case.
func _check_glide(dx: int, dy: int, expected_facing: String, expect_flip: bool, label: String) -> void:
	var world := _build_world(5, 5)
	var sprites := ColonistSpritesType.new()
	var driver := _driver_at(world, TickDriverType.Speed.X1)
	sprites.set_tick_driver(driver)
	sprites.set_world(world)

	var tick_interval := driver.seconds_per_tick() * world.get_move_ticks_per_tile()
	_expect(tick_interval > 0.0, label + ": x1 must report a positive tick interval")

	world._colonists[0]["x"] = 5 + dx
	world._colonists[0]["y"] = 5 + dy
	sprites.refresh()

	var sprite: AnimatedSprite2D = sprites._sprites["colonist_0"]
	var previous := Vector2(5, 5)
	var current := Vector2(5 + dx, 5 + dy)

	sprites.advance(0.0)
	_expect(sprite.position.is_equal_approx(previous * TILE_SIZE + SPRITE_POSITION_OFFSET),
		label + ": t=0 position must sit at the previous tile")

	sprites.advance(tick_interval * 0.5)
	var expected_mid := previous.lerp(current, 0.5) * TILE_SIZE + SPRITE_POSITION_OFFSET
	_expect(sprite.position.is_equal_approx(expected_mid), label + ": t=0.5 position must be the tile midpoint")

	sprites.advance(tick_interval * 0.5)
	_expect(sprite.position.is_equal_approx(current * TILE_SIZE + SPRITE_POSITION_OFFSET),
		label + ": t=1 position must sit at the new tile")

	_expect(sprite.animation == "walk_" + expected_facing,
		label + ": animation must be walk_%s (got %s)" % [expected_facing, sprite.animation])
	_expect(sprite.flip_h == expect_flip, label + ": flip_h must be %s (got %s)" % [expect_flip, sprite.flip_h])
	_expect(not sprite.is_playing(), label + ": frame advancement must be driven by t, not autoplay")

	sprites.free()
	driver.free()

## A tile change of Chebyshev distance > 1 (a catch-up burst at x3, or any
## other larger jump) must snap immediately: previous_tile == current_tile ==
## the new tile, no glide, even once real time has passed.
func _check_snap_on_large_jump() -> void:
	var world := _build_world(2, 2)
	var sprites := ColonistSpritesType.new()
	var driver := _driver_at(world, TickDriverType.Speed.X1)
	sprites.set_tick_driver(driver)
	sprites.set_world(world)

	world._colonists[0]["x"] = 10
	sprites.refresh()
	sprites.advance(driver.seconds_per_tick())

	var sprite: AnimatedSprite2D = sprites._sprites["colonist_0"]
	_expect(sprite.position.is_equal_approx(Vector2(10, 2) * TILE_SIZE + SPRITE_POSITION_OFFSET),
		"a >1-tile jump must snap immediately, with no glide")
	var state: Dictionary = sprites._motion["colonist_0"]
	_expect(state["previous_tile"] == state["current_tile"], "a >1-tile jump must leave previous_tile == current_tile")

	sprites.free()
	driver.free()

## A colonist with no existing state (first refresh: spawn, or newly visible
## in world.get_colonists()) snaps with no glide.
func _check_snap_on_spawn() -> void:
	var world := _build_world(3, 4)
	var sprites := ColonistSpritesType.new()
	sprites.set_world(world)
	var state: Dictionary = sprites._motion["colonist_0"]
	_expect(state["previous_tile"] == state["current_tile"], "a brand-new colonist must snap with no glide")
	_expect(state["previous_tile"] == Vector2i(3, 4), "a brand-new colonist's snap tile must match its spawn tile")
	sprites.free()

## seconds_per_tick() == 0.0 (paused) must freeze both the drawn position and
## the animation frame exactly where they were, even given a large delta.
func _check_paused_freezes_t() -> void:
	var world := _build_world(5, 5)
	var sprites := ColonistSpritesType.new()
	var driver := _driver_at(world, TickDriverType.Speed.X1)
	sprites.set_tick_driver(driver)
	sprites.set_world(world)

	world._colonists[0]["x"] = 6
	sprites.refresh()
	sprites.advance(driver.seconds_per_tick() * 0.5)

	var sprite: AnimatedSprite2D = sprites._sprites["colonist_0"]
	var frozen_position: Vector2 = sprite.position
	var frozen_frame: int = sprite.frame

	driver.pause()
	sprites.advance(10.0)
	_expect(sprite.position == frozen_position, "paused (seconds_per_tick() == 0.0) must freeze the drawn position")
	_expect(sprite.frame == frozen_frame, "paused (seconds_per_tick() == 0.0) must freeze the animation frame")

	sprites.free()
	driver.free()

## set_world() (Load, New Game) must clear all per-colonist state so the very
## next refresh() treats every colonist as brand-new: previous_tile ==
## current_tile for every colonist, regardless of what an earlier world's
## colonists were doing.
func _check_snap_on_new_game() -> void:
	var world_a := _build_world(3, 3)
	var world_b := WorldStateType.new(2, 10)
	world_b._tiles.fill(WorldStateType.TILE_FLOOR)
	world_b._colonists.clear()
	world_b._colonists.append({"id": "colonist_1", "kind": "colonist", "x": 7, "y": 7, "route": null, "work": null, "carrying": null})
	world_b._colonists.append({"id": "colonist_2", "kind": "colonist", "x": 9, "y": 1, "route": null, "work": null, "carrying": null})

	var sprites := ColonistSpritesType.new()
	sprites.set_world(world_a)
	world_a._colonists[0]["x"] = 4
	sprites.refresh() # mid-glide state for world_a's own colonist, discarded below

	sprites.set_world(world_b)
	_expect(sprites._motion.size() == 2, "the second set_world()'s first refresh must see both of world_b's colonists")
	for colonist_id in sprites._motion:
		var state: Dictionary = sprites._motion[colonist_id]
		_expect(state["previous_tile"] == state["current_tile"],
			"set_world() must leave no glide for " + String(colonist_id))
	sprites.free()

func _check_trapped_marker_visibility() -> void:
	var world := _build_world(4, 4)
	world._colonists[0]["trapped"] = {"tile": Vector2i(4, 4), "ticksRemaining": 40, "fromTile": Vector2i(3, 4)}
	var sprites := ColonistSpritesType.new()
	sprites.set_world(world)
	var marker: Sprite2D = sprites._trapped_markers["colonist_0"]
	_expect(marker.visible, "a trapped colonist must show the actor-atlas warning marker")
	world._colonists[0]["trapped"] = null
	sprites.refresh()
	_expect(not marker.visible, "the trapped marker must hide after WorldState clears trapped")
	sprites.free()

func _command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": kind, "payload": payload})

## A single colonist on open floor, forage-ordered against a berry_bush placed
## 11 tiles away: forage's router trims the final (impassable, per
## content/objects.json) target tile, so the resolved path ends adjacent to
## it -- exactly a 10-tile route, needing no tool (unlike dig/mine/chop, so
## the walk below is the whole story, no fetch_tool leg first).
func _build_straight_route_world() -> WorldStateType:
	var world := _build_world(0, 5)
	var place_result := _command(world, "place_bush", "place_object", {"x": 11, "y": 5, "kind": "berry_bush"})
	_expect(place_result["ok"], "straight-route fixture: placing the berry_bush must be accepted")
	var forage_result := _command(world, "forage_1", "forage", {"x": 11, "y": 5, "priority": 1})
	_expect(forage_result["ok"], "straight-route fixture: forage order must be accepted")
	return world

## A one-tile-wide rock corridor forcing an unambiguous L-shaped path (route
## search is 4-directional, see game/scripts/core/routing/README.md): five
## tiles east from (0,0) to (5,0), then five tiles south to (5,5), adjacent to
## a berry_bush placed on the corridor's own last cell (5,6).
func _build_l_route_world() -> WorldStateType:
	var world := WorldStateType.new(1, 10)
	world._tiles.fill(WorldStateType.TILE_ROCK)
	for x in range(0, 6):
		world._tiles[world._tile_index(x, 0)] = WorldStateType.TILE_FLOOR
	for y in range(0, 7):
		world._tiles[world._tile_index(5, y)] = WorldStateType.TILE_FLOOR
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null, "carrying": null})
	var place_result := _command(world, "place_bush", "place_object", {"x": 5, "y": 6, "kind": "berry_bush"})
	_expect(place_result["ok"], "L-route fixture: placing the berry_bush must be accepted")
	var forage_result := _command(world, "forage_1", "forage", {"x": 5, "y": 6, "priority": 1})
	_expect(forage_result["ok"], "L-route fixture: forage order must be accepted")
	return world

## Drives world.tick() + sprites.advance(FRAME_DELTA) exactly as TickDriver's
## own _process()/ColonistSprites' own _process() do in the real frame loop
## (advance(frame_delta) once per simulated rendered frame), recording every
## frame's (frame index, WorldState tick, sprite pixel position). Stops
## move_ticks_per_tile ticks after the colonist's route clears (arrival), so
## the final glide segment's one-tile visual lag (see orders-and-movement.md's
## "travel is continuous across tile boundaries") finishes before sampling
## ends, or after MAX_ROUTE_TICKS as a bound against a colonist that never
## arrives at all.
func _drive_and_sample(world: WorldStateType, sprites: ColonistSpritesType, colonist_id: String) -> Array:
	var move_ticks_per_tile := world.get_move_ticks_per_tile()
	var frames_per_tick := int(round((sprites._tick_driver.seconds_per_tick()) / FRAME_DELTA))
	var samples: Array = []
	var frame_index := 0
	var settle_ticks_left := -1
	for _tick_i in MAX_ROUTE_TICKS:
		world.tick()
		sprites.refresh()
		for _f in frames_per_tick:
			sprites.advance(FRAME_DELTA)
			var pos: Vector2 = (sprites._sprites[colonist_id] as AnimatedSprite2D).position
			samples.append({"frame": frame_index, "tick": world.get_tick(), "x": pos.x, "y": pos.y})
			frame_index += 1
		var colonist: Dictionary = world._find_colonist(colonist_id)
		if settle_ticks_left < 0 and colonist["route"] == null and colonist.get("work") != null:
			settle_ticks_left = move_ticks_per_tile
		elif settle_ticks_left >= 0:
			settle_ticks_left -= 1
			if settle_ticks_left < 0:
				break
	return samples

## Per-frame Euclidean pixel displacement between consecutive samples, plus
## the index of the first and last frame that actually moved -- the per-tile
## stutter bug's signature is a zero-displacement frame strictly between those two
## indices (the sprite frozen at the destination pixel for 3 of every 4
## ticks), which _run_route_glide_check() below asserts against directly.
func _analyze_samples(samples: Array) -> Dictionary:
	var displacements: Array = []
	for i in range(samples.size() - 1):
		var a: Dictionary = samples[i]
		var b: Dictionary = samples[i + 1]
		displacements.append(Vector2(b["x"] - a["x"], b["y"] - a["y"]).length())
	var first_move := -1
	var last_move := -1
	for i in displacements.size():
		if displacements[i] > DISPLACEMENT_EPSILON:
			if first_move == -1:
				first_move = i
			last_move = i
	return {"displacements": displacements, "first_move": first_move, "last_move": last_move}

## Runs one drive-and-sample pass at `speed` against an already-job-submitted
## `world`, asserting: the colonist actually moved; no interior (mid-route)
## frame has zero displacement (only frames strictly before the first
## crossing starts or after the last one ends may be zero); and every moving
## frame's displacement sits within DISPLACEMENT_TOLERANCE_PX of the route's
## own mean pace. Returns that mean pace (px/frame) for the caller's own
## x1/x2/x3 scaling check.
func _run_route_glide_check(world: WorldStateType, speed: int, speed_label: String) -> float:
	var sprites := ColonistSpritesType.new()
	var driver := _driver_at(world, speed)
	sprites.set_tick_driver(driver)
	sprites.set_world(world)

	var samples := _drive_and_sample(world, sprites, "colonist_0")
	var analysis := _analyze_samples(samples)
	var first_move: int = analysis["first_move"]
	var last_move: int = analysis["last_move"]
	var displacements: Array = analysis["displacements"]
	_expect(first_move != -1 and last_move != -1, speed_label + ": the colonist must actually move during the sampled route")

	var mean := 0.0
	if first_move != -1:
		var sum := 0.0
		for i in range(first_move, last_move + 1):
			_expect(displacements[i] > DISPLACEMENT_EPSILON,
				speed_label + ": frame %d is mid-route (between the first and last moving frames) but shows zero displacement -- the per-tile pause bug" % i)
			sum += displacements[i]
		mean = sum / float(last_move - first_move + 1)
		for i in range(first_move, last_move + 1):
			_expect(absf(displacements[i] - mean) <= DISPLACEMENT_TOLERANCE_PX,
				speed_label + ": frame %d displacement %.4f must stay within %.1fpx of the route's constant %.4f px/frame pace" %
					[i, displacements[i], DISPLACEMENT_TOLERANCE_PX, mean])

	sprites.free()
	driver.free()
	return mean

## A 10-tile straight open-floor route glides at constant visual
## speed with no per-tile pause at x1, and the same holds at x2/x3 with
## per-frame displacement scaled 2x/3x (frames_per_tick halves/thirds while
## FRAME_DELTA and the tile's pixel size stay fixed, so the pace scales
## exactly, not just approximately).
func _check_constant_glide_across_straight_route() -> void:
	var mean_x1 := _run_route_glide_check(_build_straight_route_world(), TickDriverType.Speed.X1, "straight route x1")
	var mean_x2 := _run_route_glide_check(_build_straight_route_world(), TickDriverType.Speed.X2, "straight route x2")
	var mean_x3 := _run_route_glide_check(_build_straight_route_world(), TickDriverType.Speed.X3, "straight route x3")
	_expect(mean_x1 > 0.0, "straight route: x1 must have a positive constant pace to compare against")
	_expect(absf(mean_x2 - mean_x1 * 2.0) <= DISPLACEMENT_TOLERANCE_PX,
		"straight route: x2's pace (%.4f) must be ~2x x1's (%.4f)" % [mean_x2, mean_x1])
	_expect(absf(mean_x3 - mean_x1 * 3.0) <= DISPLACEMENT_TOLERANCE_PX,
		"straight route: x3's pace (%.4f) must be ~3x x1's (%.4f)" % [mean_x3, mean_x1])

## An L-shaped route (straight leg, 90-degree turn, straight leg)
## has no zero-displacement frame at or around the corner -- reusing
## _run_route_glide_check()'s own "no interior zero frame" assertion, which
## already spans the corner since it covers every frame between the first and
## last moving frames of the whole route, corner included.
func _check_l_shaped_route_has_no_pause_at_corner() -> void:
	_run_route_glide_check(_build_l_route_world(), TickDriverType.Speed.X1, "L-shaped route x1")

## Prints (frame, WorldState tick, pixel x, pixel y) for the
## straight route's first tile-crossing at x1, for comparing glide timing
## before and after a change -- never invoked by the normal PASS/FAIL run
## above.
## godot --headless --path game --script res://scripts/tests/test_colonist_sprites.gd -- --measure
func _print_measurement_table() -> void:
	var world := _build_straight_route_world()
	var sprites := ColonistSpritesType.new()
	var driver := _driver_at(world, TickDriverType.Speed.X3)
	sprites.set_tick_driver(driver)
	sprites.set_world(world)
	var frames_per_tick := int(round(driver.seconds_per_tick() / FRAME_DELTA))
	var samples := _drive_and_sample(world, sprites, "colonist_0")
	var analysis := _analyze_samples(samples)
	var first_move: int = analysis["first_move"]
	# One full tile-crossing plus its leading stationary frame (x3 keeps this
	# table short -- frames_per_tick * 4 rows --
	# while still recording every advance() call from the last stationary frame
	# through the crossing's completion).
	var window_start := first_move
	var window_end := mini(samples.size() - 1, first_move + frames_per_tick * world.get_move_ticks_per_tile())
	print("frame,tick,x,y")
	for i in range(window_start, window_end + 1):
		var s: Dictionary = samples[i]
		print("%d,%d,%.4f,%.4f" % [s["frame"], s["tick"], s["x"], s["y"]])
	sprites.free()
	driver.free()
	quit()

## Optional, always-PASS-in-headless graphical evidence (test_river_map_capture.gd's
## pattern): boots a seed-42 world, positions a colonist mid-glide via a direct
## advance() call, and saves PNGs for down/up/side(+flipped) facings to
## user://captures for manual inspection.
func _capture_evidence() -> void:
	if DisplayServer.get_name() == "headless":
		quit()
		return
	var boot := Boot.new()
	root.add_child(boot)
	boot.tick_driver.pause()
	if boot._map_view == null:
		boot._build_ui()
	boot._seed_input.text = "42"
	boot._on_new_game_pressed()
	boot._on_new_game_confirmed()
	boot._new_game_confirm.hide()
	await process_frame

	var sprites = boot._map_view._colonist_sprites
	var colonist_id := String(boot.world.get_colonists()[0]["id"])
	var tick_interval := boot.tick_driver.seconds_per_tick()

	for entry in [["down", Vector2i(0, 1), false], ["up", Vector2i(0, -1), false], ["side", Vector2i(1, 0), true]]:
		var facing: String = entry[0]
		var step: Vector2i = entry[1]
		var colonist: Dictionary = boot.world._find_colonist(colonist_id)
		var origin := Vector2i(int(colonist["x"]), int(colonist["y"]))
		boot.world._colonists[0]["x"] = origin.x + step.x
		boot.world._colonists[0]["y"] = origin.y + step.y
		boot._map_view.refresh()
		sprites.advance(tick_interval * 0.5)
		await RenderingServer.frame_post_draw
		var path := ProjectSettings.globalize_path(EVIDENCE_DIR)
		DirAccess.make_dir_recursive_absolute(path)
		var flip_label := "-flipped" if entry[2] else ""
		root.get_texture().get_image().save_png(path.path_join("colonist-mid-glide-%s%s.png" % [facing, flip_label]))

	boot.queue_free()
	await process_frame
	quit()
