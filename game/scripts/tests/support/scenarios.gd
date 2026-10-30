extends RefCounted

## Scenario builders shared by the headless tests (R15). Each one was copied verbatim into
## several test files before; none asserts anything, so moving them here changes no check.
## Use: const Scenarios = preload("res://scripts/tests/support/scenarios.gd")

const WorldStateType = preload("res://scripts/core/world_state.gd")

## A rock row at y from x = 0 to gap_x - 1, open from gap_x to the east edge.
## A8 (ADR 054): A* resolves an open-floor route in about one expansion per
## tile of distance, so a check that needs a genuinely multi-tick route search
## puts this between the searcher and its target: the detour through the gap
## makes the search expand the whole area on its own side first. Raw tile
## writes, so the passability cache and the region and room maps are dropped
## and rebuilt on their next query.
static func rock_row_with_gap(world: WorldStateType, y: int, gap_x: int) -> void:
	for x in gap_x:
		TestAccess.set_tile(world, x, y, WorldStateType.TILE_ROCK)
	TestAccess.tile_grid(world).reset_cells()
	TestAccess.tile_grid(world).regions = null
	TestAccess.tile_grid(world).rooms = null

## A world whose tiles are all floor, with no colonists.
static func floor_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	return world

## floor_world() with the generated objects removed as well.
static func empty_floor_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value)
	TestAccess.tile_grid(world).tiles.fill(WorldStateType.TILE_FLOOR)
	TestAccess.colonists(world).clear()
	TestAccess.object_table(world).objects.clear()
	return world

## Applies a command as the "test" actor at the current tick.
static func command(world: WorldStateType, command_id: String, command_type: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": command_id, "tick": world.get_tick(),
		"type": command_type, "payload": payload})

## Zeroes every need kind's decay rate except `kind` ("" zeroes them all), so a scenario
## built around one need is never disturbed by another crossing its own threshold first.
## Each world loads its own need definitions, so this never leaks between test worlds.
static func isolate_need(world: WorldStateType, kind: String) -> void:
	for other in TestAccess.need_definitions(world).keys():
		if other != kind:
			TestAccess.need_definitions(world)[other]["rate_per_day"] = 0

## An idle colonist record with full needs, ready to append to the roster.
static func idle_colonist(id: String, x: int, y: int) -> Dictionary:
	return {"id": id, "kind": "colonist", "x": x, "y": y, "z": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"route": null, "work": null, "carrying": null}

## Full needs (100 each), with `overrides` applied per kind.
static func full_needs(overrides: Dictionary = {}) -> Dictionary:
	var needs := {"food": 100, "water": 100, "rest": 100}
	for kind in overrides:
		needs[kind] = overrides[kind]
	return needs

## Drops a ground stack of `kind` at (x, y) straight into the item table.
static func add_stock(world: WorldStateType, kind: String, count: int, x: int, y: int) -> void:
	var id := "item_%d" % TestAccess.item_table(world).next_item_id
	TestAccess.item_table(world).items[id] = {"id": id, "x": x, "y": y, "z": 0, "kind": kind, "count": count}
	TestAccess.item_table(world).next_item_id += 1

## Public job views of one kind, in get_jobs() order.
static func jobs_of_kind(world: WorldStateType, kind: String) -> Array[Dictionary]:
	var jobs: Array[Dictionary] = []
	for job in world.get_jobs():
		if String(job["kind"]) == kind:
			jobs.append(job)
	return jobs

## The public job view for job_id, or {}.
static func find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

## The public colonist view for colonist_id, or {}.
static func colonist_by_id(world: WorldStateType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}
