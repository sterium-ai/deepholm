extends SceneTree

## Coverage for colonist_panel.gd's toil display:
## a hauling colonist's panel line must show its job kind ("Hauling") and its
## current toil name, exercised end to end through a real WorldState (auto
## haul submission, the global scheduler, and the toil executor) rather than
## a synthetic colonist/job pair, so this stays honest about what
## ColonistPanel._line_for() actually renders.

const WorldStateType = preload("res://scripts/core/world_state.gd")
const ColonistPanelType = preload("res://scripts/viewer/colonist_panel.gd")
const TextTableType = preload("res://scripts/viewer/text_table.gd")
const InventoryType = preload("res://scripts/core/actors/components/inventory.gd")
const TileAtlasMapType = preload("res://scripts/viewer/tile_atlas_map.gd")

var _failed := false

func _init() -> void:
	_check_hauling_colonist_shows_job_and_toil("wood")
	_check_hauling_colonist_shows_job_and_toil("stone")
	_check_tool_display()
	_check_no_tool_reason()
	_check_handover_reason()

	if _failed:
		quit(1)
		return
	print("test_colonist_panel_toil: PASS")
	quit()

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## A single colonist starts on a loose wood item and a stockpile zone sits
## five tiles away, so pick_up happens on the very first active tick and the
## colonist then spends several ticks firmly mid-route on leg two
## (hands is non-empty, route != null) before place() ever runs -- the same
## "strictly mid-carry" wait test_haul_stockpile.gd's own checks use, chosen
## so the toil this test asserts on is never the single ambiguous tick right
## after pick_up (hands just populated, leg-two route not started yet).
func _check_hauling_colonist_shows_job_and_toil(item_kind: String) -> void:
	var world := WorldStateType.new(24601, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({
		"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "hands": [],
	})
	world._items["item_1"] = {"id": "item_1", "x": 0, "y": 0, "kind": item_kind, "count": 1}
	world._next_item_id = 2
	var zone_result: Dictionary = world.apply({
		"actor": "test", "command_id": "zone_setup", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 5, "y": 5, "width": 1, "height": 1},
	})
	_expect(zone_result.get("ok", false), "zone_add setup must succeed")

	var mid_route := false
	for _i in 60:
		world.tick()
		var colonist := world.get_colonists()[0]
		if InventoryType.is_carrying(colonist) and colonist.get("route") != null:
			mid_route = true
			break
	_expect(mid_route, "setup must reach a colonist mid-route on haul leg two (hands occupied, en route to the zone)")
	if not mid_route:
		return

	var colonist := world.get_colonists()[0]
	var sprites = load("res://scripts/viewer/colonist_sprites.gd").new()
	sprites.set_world(world)
	var marker: Sprite2D = sprites._carried_markers["colonist_0"]
	var atlas: Dictionary = load("res://scripts/viewer/tile_atlas_map.gd").ITEM_ATLAS_MAP[item_kind]
	_expect(marker.visible, "real haul must show the carried " + item_kind)
	_expect(marker.texture.resource_path == atlas["texture_path"] and marker.region_rect == atlas["rect"], "cargo badge must resolve the actual carried kind: " + item_kind)
	# Marker position now follows the sprite's own interpolated,
	# feet-anchored position (SPRITE_POSITION_OFFSET) instead of the raw tile
	# origin -- this sprite is freshly spawned as of set_world() above (no
	# prior motion state), so it is snapped with t=0 at its current tile,
	# matching the position refresh()/advance() draw right now.
	_expect(marker.position == Vector2(colonist["x"], colonist["y"]) * 16.0 + sprites.SPRITE_POSITION_OFFSET + sprites.CARRIED_MARKER_OFFSET, "cargo keeps the established marker position")
	_expect(marker.scale * marker.region_rect.size == sprites.CARRIED_MARKER_SIZE, "cargo keeps the established marker dimensions")
	var panel := ColonistPanelType.new()
	panel.world = world
	panel._text_table = TextTableType.new()
	var line: String = panel._line_for(colonist)

	_expect(line.find("Hauling") >= 0,
		"the panel line must show the job-kind label for a hauling colonist (got: %s)" % line)
	_expect(line.find("Toil: Traveling") >= 0,
		"the panel line must include the colonist's current toil name (got: %s)" % line)
	panel.free()
	for _i in 60:
		world.tick()
		if not InventoryType.is_carrying(world.get_colonists()[0]):
			break
	sprites.refresh()
	_expect(not marker.visible, "placing cargo clears the badge: " + item_kind)
	var delivered := false
	for item in world.get_items():
		if item["kind"] == item_kind and int(item["x"]) == 5 and int(item["y"]) == 5:
			delivered = true
	_expect(delivered, "real haul must deliver " + item_kind)
	sprites.free()


func _panel(world: WorldStateType) -> ColonistPanelType:
	var panel := ColonistPanelType.new()
	panel.world = world
	panel._text_table = TextTableType.new()
	return panel

func _check_tool_display() -> void:
	var world := WorldStateType.new(274)
	var panel := _panel(world)
	var sprites = load("res://scripts/viewer/colonist_sprites.gd").new()
	sprites.set_world(world)
	var colonist := world.get_colonists()[0]
	var id := String(colonist["id"])
	_expect(not panel._line_for(colonist).contains("Held tool:"), "empty hands have no tool label")
	_expect(not sprites._tool_markers[id].visible, "empty hands have no tool marker")
	for kind in ["axe", "pick"]:
		var tool_id := world.spawn_ground_tool_item(kind, 0, 0)
		_expect(world.set_tool_item_held(tool_id, id), "tool display setup must equip " + kind)
		sprites.refresh()
		_expect(panel._line_for(world.get_colonists()[0]).contains("Held tool: " + kind), "panel resolves held item kind")
		_expect(sprites._tool_markers[id].visible, "held tool marker is visible")
		var marker: Sprite2D = sprites._tool_markers[id]
		var atlas: Dictionary = TileAtlasMapType.ITEM_ATLAS_MAP[kind]
		_expect(marker.region_rect == atlas["rect"], "tool marker resolves registered region: " + kind)
		_expect(marker.texture.resource_path == atlas["texture_path"], "tool marker resolves registered texture: " + kind)
		_expect(marker.modulate == Color.WHITE, "tool marker keeps untinted source pixels: " + kind)
		_expect(marker.scale * marker.region_rect.size == sprites.TOOL_MARKER_SIZE, "tool marker keeps established dimensions")
		_expect(marker.position == sprites._sprites[id].position + sprites.TOOL_MARKER_OFFSET, "tool marker keeps established offset")
		_expect(world.set_tool_item_ground(tool_id, 0, 0), "drop tool setup")
		sprites.refresh()
		_expect(not sprites._tool_markers[id].visible, "drop clears marker on refresh")
		_expect(not panel._line_for(world.get_colonists()[0]).contains("Held tool:"), "drop clears panel label")
	world._colonists.clear()
	sprites.refresh()
	_expect(sprites._tool_markers.is_empty(), "removed colonists leave no tool markers")
	sprites.free()
	panel.free()

func _command(world: WorldStateType, id: String, kind: String, payload: Dictionary) -> Dictionary:
	return world.apply({"actor": "test", "command_id": id, "tick": world.get_tick(), "type": kind, "payload": payload})

func _check_no_tool_reason() -> void:
	var world := WorldStateType.new(274)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_TREE
	_expect(_command(world, "chop", "chop", {"x": 1, "y": 0}).get("ok", false), "chop accepted without tool")
	var panel := _panel(world)
	var seen := false
	for _i in 40:
		world.tick()
		for job in world.get_jobs():
			if job.get("reason") == "blocked_no_tool":
				seen = true
				var line := panel._line_for(world.get_colonists()[0])
				_expect(line.contains("Reason: No reachable, available tool matches this job"), "blocked tool reason translated")
				_expect(line.contains("Remedy: Craft or find a reachable tool of the required kind"), "blocked tool remedy translated")
		if seen:
			break
	_expect(seen, "real chop reaches blocked_no_tool")
	panel.free()

func _find_job(world: WorldStateType, job_id: String) -> Dictionary:
	for job in world.get_jobs():
		if String(job["id"]) == job_id:
			return job
	return {}

func _find_colonist(world: WorldStateType, colonist_id: String) -> Dictionary:
	for colonist in world.get_colonists():
		if String(colonist["id"]) == colonist_id:
			return colonist
	return {}


func _check_handover_reason() -> void:
	var world := WorldStateType.new(266104)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(10, 9)] = WorldStateType.TILE_TREE
	world._colonists.clear()
	world._colonists.append({"id": "colonist_a", "kind": "colonist", "x": 0, "y": 0, "route": null, "work": null,
		"labourTable": {"chop": 0}})
	world._colonists.append({"id": "colonist_b", "kind": "colonist", "x": 10, "y": 10, "route": null, "work": null,
		"labourTable": {"forage": 0}})
	var axe_id := world.spawn_ground_tool_item("axe", 0, 0)
	_expect(world.set_tool_item_held(axe_id, "colonist_a"), "moving the axe into colonist_a's hand must succeed")

	_expect(_command(world, "place_bush_a", "place_object", {"x": 1, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush A placement must be accepted")
	_expect(_command(world, "place_bush_b", "place_object", {"x": 3, "y": 0, "kind": "berry_bush"}).get("ok", false),
		"berry_bush B placement must be accepted")
	var forage_a := _command(world, "forage_a", "forage", {"x": 1, "y": 0, "priority": 1})
	_expect(forage_a.get("ok", false), "forage_a submission must be accepted")
	var forage_a_id := String(forage_a.get("job_id", ""))

	var ticks := 0

	# colonist_a must already be genuinely busy on forage_a -- a real, active
	# job that needs no tool -- before chop_b (and its axe reservation) ever
	# exists, or the direct-idle-holder steal path would run instead of the
	# handover wait this scenario is about.
	var colonist_a_busy := false
	for _i in 20:
		world.tick()
		ticks += 1
		var colonist_a := _find_colonist(world, "colonist_a")
		if colonist_a.get("route") != null or colonist_a.get("work") != null:
			colonist_a_busy = true
			break
	_expect(colonist_a_busy, "colonist_a must be busy on forage_a before chop_b (and its axe reservation) ever exists")

	var chop_b := _command(world, "chop_b", "chop", {"x": 10, "y": 9, "priority": 1})
	_expect(chop_b.get("ok", false), "chop_b submission must be accepted")
	var chop_b_id := String(chop_b.get("job_id", ""))

	var panel := _panel(world)
	var waiting_seen := false
	var completed := false
	var forage_a_done := false
	while ticks < 400:
		world.tick()
		ticks += 1
		if not forage_a_done:
			for job in world.get_jobs():
				if job["id"] == forage_a_id and job["status"] == "completed":
					forage_a_done = true
					# colonist_a's own next dispatched job -- submitted only
					# now, so a third job is never queued while colonist_b
					# waits -- is what makes its first toil drop_tool.
					var forage_b := _command(world, "forage_b", "forage", {"x": 3, "y": 0, "priority": 1})
					_expect(forage_b.get("ok", false), "forage_b must be accepted right as forage_a completes")
		var chop_job := _find_job(world, chop_b_id)
		if String(chop_job.get("reason", "")) == "waiting_for_tool_handover":
			waiting_seen = true
			var line := panel._line_for(_find_colonist(world, "colonist_b"))
			_expect(line.contains("Reason: Waiting for another colonist to drop the reserved tool"), "active handover reason translated")
			_expect(line.contains("Remedy: Wait for the holder to drop the tool"), "active handover remedy translated")
			_expect(String(chop_job.get("item_id", "")) == axe_id,
				"waiting_for_tool_handover's itemId must name the reserved axe, got '%s'" % chop_job.get("item_id"))
			_expect(String(_find_colonist(world, "colonist_b").get("held_tool", "")) == "",
				"colonist_b must not hold the axe while genuinely waiting for the handover")
		if String(chop_job.get("status", "")) == "completed":
			completed = true
			break
	_expect(waiting_seen, "chop_b must expose reason waiting_for_tool_handover while colonist_a still holds the axe")
	_expect(completed,
		"chop_b must complete, within %d total ticks, once colonist_a's own next dispatched job drops the axe (took %d)" %
			[400, ticks])
	_expect(String(_find_colonist(world, "colonist_b").get("held_tool", "")) == axe_id,
		"colonist_b must end up holding the axe it waited for")

	var drop_seen := false
	for entry in world._toils.trace:
		if String(entry.get("toil", "")) == "drop_tool" and String(entry.get("phase", "")) == "complete":
			drop_seen = true
	_expect(drop_seen, "colonist_a must have run a drop_tool toil to release the handover: %s" % [world._toils.trace])

	panel.free()
