extends Node2D

## Subtle designation fill: marks every tile with a
## pending order (WorldState.get_jobs() status 'queued' or 'active'), at that
## job's 'target' coordinate. Reads world state only -- never mutates it -- so
## test_viewer_hash.gd's state_hash() comparison stays unaffected by adding
## this node. Independent of map_view's art-mode toggle: orders exist
## regardless of which renderer draws the tiles underneath, so this overlay
## stays visible in both.

const WorldStateType = preload("res://scripts/core/world_state.gd")

## Mirrors MapView.TILE_SIZE. Not shared via preload to avoid a preload cycle
## (map_view.gd preloads this script to instantiate the overlay); both must
## be kept in sync if the tile size ever changes.
const TILE_SIZE := 16.0

const PENDING_STATUSES := ["queued", "active"]
const OUTLINE_COLOR := Color(1.0, 0.85, 0.1, 0.20)

var world: WorldStateType

func set_world(world_ref: WorldStateType) -> void:
	world = world_ref
	queue_redraw()

func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	if world == null:
		return
	for job in world.get_jobs():
		if String(job["status"]) not in PENDING_STATUSES:
			continue
		var target: Vector2i = job["target"]
		draw_rect(Rect2(
			target.x * TILE_SIZE,
			target.y * TILE_SIZE,
			TILE_SIZE,
			TILE_SIZE
		), OUTLINE_COLOR, true)
