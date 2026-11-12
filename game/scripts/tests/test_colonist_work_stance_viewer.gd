extends SceneTree

## B9: colonist_sprites.gd's work stance. A colonist digging from an adjacent tile
## (ADR 013) faces its job's target -- up/down, or side with flip_h toward the west --
## and, when the pack measured that work animation's tool_tip (colonist_pack.json),
## its body shifts by a "work_offset" of at most MAX_WORK_OFFSET per axis that puts the
## tip inside the target tile (without the pack, tools/sync_pack_assets.ps1, the offset
## stays zero); once the job is done the offset returns to zero. Driven directly against a
## ticking WorldState, no scene.
##
## godot --headless --path game --script res://scripts/tests/test_colonist_work_stance_viewer.gd

const WorldStateType = preload("res://scripts/core/world_state.gd")
const Scenarios = preload("res://scripts/tests/support/scenarios.gd")
const ColonistSpritesType = preload("res://scripts/viewer/colonist_sprites.gd")
const SpriteRecordType = preload("res://scripts/viewer/sprite_record.gd")

var _failed := false

func _init() -> void:
	_check_faces_target(Vector2i(1, 0), "side", false, "a target to the east")
	_check_faces_target(Vector2i(-1, 0), "side", true, "a target to the west (flipped)")
	_check_faces_target(Vector2i(0, -1), "up", false, "a target to the north")
	_check_faces_target(Vector2i(0, 1), "down", false, "a target to the south")
	if _failed:
		quit(1)
		return
	print("test_colonist_work_stance_viewer: PASS")
	quit(0)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failed = true
		push_error(message)

## A plus-shaped soil patch around (3,3): the colonist stands at (3,3) with a shovel
## underfoot, and the only walkable neighbour of the target is (3,3) itself, so the
## digger works from exactly there.
func _world_with_dig(direction: Vector2i) -> WorldStateType:
	var world := WorldStateType.new(4242, 10)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_ROCK)
	var target := Vector2i(3, 3) + direction
	TestAccess.set_tile(world, 3, 3, WorldStateType.TILE_SOIL)
	TestAccess.set_tile(world, target.x, target.y, WorldStateType.TILE_SOIL)
	TestAccess.colonists(world).clear()
	TestAccess.colonists(world).append({"id": "colonist_0", "kind": "colonist", "x": 3, "y": 3, "z": 0,
		"route": null, "work": null, "carrying": null})
	world.spawn_ground_tool_item("shovel", 3, 3)
	var submitted := Scenarios.command(world, "dig_1", "dig", {"x": target.x, "y": target.y, "z": 0, "priority": 1})
	_expect(submitted.get("ok", false), "dig at %s must be accepted" % target)
	return world

func _check_faces_target(direction: Vector2i, expected_facing: String, expect_flip: bool, label: String) -> void:
	var world := _world_with_dig(direction)
	var sprites := ColonistSpritesType.new()
	sprites.set_world(world)
	var saw_work := false
	for _i in 200:
		world.tick()
		sprites.refresh()
		var colonist: Dictionary = TestAccess.colonists(world)[0]
		if colonist.get("work") == null:
			if saw_work:
				break
			continue
		saw_work = true
		var state: Dictionary = sprites._motion["colonist_0"]
		_expect(Vector2i(state["current_tile"]) == Vector2i(3, 3), "%s: the digger must work from (3,3)" % label)
		_expect(state["facing"] == expected_facing,
			"%s: facing must be %s, got %s" % [label, expected_facing, state["facing"]])
		_expect(bool(state["flip_h"]) == expect_flip, "%s: flip_h must be %s" % [label, expect_flip])
		var offset: Vector2 = state["work_offset"]
		_expect(absf(offset.x) <= ColonistSpritesType.MAX_WORK_OFFSET and absf(offset.y) <= ColonistSpritesType.MAX_WORK_OFFSET,
			"%s: work_offset %s must stay within MAX_WORK_OFFSET" % [label, offset])
		if sprites._tool_tips.has("dig_" + expected_facing):
			# The measured tip, relative to the colonist's tile origin, must land inside the
			# target tile and no farther from its centre than without the shift.
			var frame_tip: Vector2 = sprites._tool_tips["dig_" + expected_facing]
			if expect_flip:
				frame_tip.x = ColonistSpritesType.FRAME_SOURCE_SIZE - 1.0 - frame_tip.x
			var unshifted := ColonistSpritesType.SPRITE_POSITION_OFFSET + frame_tip
			var tile := ColonistSpritesType.TILE_SIZE
			var target_rect := Rect2(Vector2(direction) * tile, Vector2(tile, tile))
			var centre := target_rect.get_center()
			_expect(target_rect.grow(0.5).has_point(unshifted + offset),
				"%s: the tool tip %s must land in the target tile %s" % [label, unshifted + offset, target_rect])
			_expect((unshifted + offset).distance_to(centre) <= unshifted.distance_to(centre),
				"%s: work_offset %s must bring the tool tip toward the target's centre" % [label, offset])
		else:
			_expect(offset == Vector2.ZERO, "%s: without a measured tool_tip there is no work_offset" % label)
		var body: SpriteRecordType = sprites._sprites["colonist_0"]
		sprites.advance(0.0)
		_expect(body.position.is_equal_approx(Vector2(3, 3) * ColonistSpritesType.TILE_SIZE
				+ ColonistSpritesType.SPRITE_POSITION_OFFSET + offset),
			"%s: the body must be drawn at its tile plus work_offset" % label)
	_expect(saw_work, "%s: the colonist must enter its work toil" % label)
	_expect(world.get_tile(3 + direction.x, 3 + direction.y) == WorldStateType.TILE_TRENCH, "%s: the dig must finish" % label)
	_expect(sprites._motion["colonist_0"]["work_offset"] == Vector2.ZERO, "%s: work_offset must clear after the job" % label)
	sprites.free()
