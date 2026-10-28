extends RefCounted

## New-game setup for the debug viewer: places a fresh world's deterministic
## starting tools and beds (boot.gd's build_default_world() creates the world
## and calls spawn_starting_items()). Pure functions (no scene/node access),
## so boot.gd and scene-free tests (test_viewer_hash.gd) build identical worlds.
## spawn_ground_tool_item() is not a call viewer scripts may make on a world
## (test_architecture_rules.gd's viewer purity), so boot.gd passes it in.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

## Starting tools first, then beds past the tiles the tools claimed. content is
## the session registry the world was built from (A13: packs may change which
## tool a job needs), so the starting tools match that world's jobs.
static func spawn_starting_items(new_world: WorldStateType, mapgen: Dictionary, spawn_tool: Callable,
		content: ContentRegistryType) -> void:
	_spawn_starting_tools(new_world, mapgen, spawn_tool, content)
	_spawn_starting_beds(new_world, mapgen, content)

## Deterministic starting prerequisites: every job kind that
## declares a needs_tool requirement in jobs.json (dig -> pick, chop -> axe)
## gets one ground tool item within the world's own real spawn clearing
## (WorldGenerator.place_spawn()'s river-aware, resource-validated
## search, not mapgen.json's spawn_area_x/y -- that field is now only the
## absolute-last-resort fallback anchor a total search failure would use, see
## ADR 020), through the same spawn_ground_tool_item()/fetch_tool
## toil path a player-placed or world-generated tool would use -- never a
## bypass of the work engine's tool-fetch requirement, just a real tool
## actually present to fetch. Tool kinds are sorted for a placement order
## independent of jobs.json's own field order, so this stays deterministic
## for a given seed. Static (no instance state used) so build_default_world()
## can call it without a Boot node. `spawn_tool` is the world's own
## spawn_ground_tool_item(kind, x, y).
##
## Reading clearing_x/clearing_y/clearing_width and computing
## `clearing_x + i % clearing_width` blindly could place a tool on a still-
## water cell whenever a fallback tier's own rectangle metadata was not fully
## painted (or, for a repaired/constructed clearing, was never a solid
## rectangle at all). place_spawn() now returns its own already-vetted,
## never-water, never-colonist-occupied land tile pool (get_spawn_clearing()'s
## "land_tiles") for exactly this purpose; this only falls back to the old
## anchor-offset scheme when that pool is empty (a StateCodec-decoded world,
## which never calls place_spawn() at all and has no clearing/pool to read).
static func _spawn_starting_tools(new_world: WorldStateType, mapgen: Dictionary, spawn_tool: Callable,
		content: ContentRegistryType) -> void:
	var tool_kinds := _needed_tool_kinds(content)
	var tiles := _claim_starting_tiles(new_world, mapgen, tool_kinds.size() + new_world.get_colonists().size())
	for i in tool_kinds.size():
		var tile: Vector2i = tiles[i] if i < tiles.size() else _fallback_anchor(new_world, mapgen)
		spawn_tool.call(tool_kinds[i], tile.x, tile.y)

## Every job kind's needs_tool requirement (jobs.json), deduplicated and
## sorted -- shared by _spawn_starting_tools() and _spawn_starting_beds() so
## both agree on exactly how many pool tiles the tools claim, and neither
## recomputes a slightly different count.
static func _needed_tool_kinds(content: ContentRegistryType) -> Array[String]:
	var tool_kinds: Array[String] = []
	for job_def in content.list("jobs"):
		var needs_tool := String(job_def.get("needs_tool", ""))
		if not needs_tool.is_empty() and not tool_kinds.has(needs_tool):
			tool_kinds.append(needs_tool)
	tool_kinds.sort()
	return tool_kinds

## One "bed" object per colonist: normal generation supplies no other
## rest-need source, so without these the "rest" need in content/needs.json
## (source_kind "bed") would be permanently unmet on every fresh New Game.
## Placed through the same place_object command path a player-built bed would
## use (never a bypass of its own occupancy/tree/colonist validation), on the
## same guaranteed-safe land tile pool _spawn_starting_tools() above draws
## from, offset past however many tiles that call already claimed for tools so
## neither placement can land on the other's tile -- exactly colonist_count
## beds, never the whole remaining pool.
static func _spawn_starting_beds(new_world: WorldStateType, mapgen: Dictionary, content: ContentRegistryType) -> void:
	var colonist_count := new_world.get_colonists().size()
	var tool_count := _needed_tool_kinds(content).size()
	var tiles := _claim_starting_tiles(new_world, mapgen, tool_count + colonist_count)
	var bed_tiles := tiles.slice(tool_count, tool_count + colonist_count)
	for i in bed_tiles.size():
		var tile: Vector2i = bed_tiles[i]
		new_world.apply({
			"actor": "system", "command_id": "starting_bed_%d" % i, "tick": new_world.get_tick(),
			"type": "place_object", "payload": {"x": tile.x, "y": tile.y, "kind": "bed"},
		})

## The spawn clearing's own guaranteed-safe land tile pool, shared by _spawn_starting_tools()/_spawn_starting_beds() so both
## draw from the same deterministic list instead of guessing independent
## offsets that could collide with each other or with a colonist's own tile.
## `needed` is a hint only (both callers request their own full-size slice and
## take what they need by position), so a single call here can serve both.
static func _claim_starting_tiles(new_world: WorldStateType, mapgen: Dictionary, needed: int) -> Array[Vector2i]:
	var clearing := new_world.get_spawn_clearing()
	var pool: Array = clearing.get("land_tiles", [])
	var tiles: Array[Vector2i] = []
	for entry in pool:
		tiles.append(entry as Vector2i)
	if not tiles.is_empty() or needed <= 0:
		return tiles
	var anchor := _fallback_anchor(new_world, mapgen)
	for i in needed:
		tiles.append(anchor)
	return tiles

## Only reached for a StateCodec-decoded world (get_spawn_clearing() empty,
## never calls place_spawn()) or a pathological clearing with no land tile
## pool at all -- mapgen.json's own documented last-resort anchor, clamped
## in-bounds.
static func _fallback_anchor(new_world: WorldStateType, mapgen: Dictionary) -> Vector2i:
	return Vector2i(
		clampi(int(mapgen.get("spawn_area_x", 0)), 0, maxi(0, new_world.get_map_width() - 1)),
		clampi(int(mapgen.get("spawn_area_y", 0)), 0, maxi(0, new_world.get_map_height() - 1))
	)
