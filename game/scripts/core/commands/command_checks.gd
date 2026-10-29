class_name CommandChecks
extends RefCounted

## Read-only pre-mutation rules shared by the command handlers (commands/handlers/) and
## preview(), so a preview needs no state copy. Each check mirrors its handler's rejection
## order and returns {} or {"reason", "params"}; it never mutates `world`. JobQueue rules are
## called through its pure predicates (check_submission(), check_terminal()), never copied.
## Like StateCodec, it reads WorldState's underscore members (_tile_grid, _object_table,
## _zone_table, _passability, _construction, _scheduler, ...) as its command-rule companion.

## Dispatches command["type"] to its check; an unknown type gets apply()'s own
## unknown_command_type rejection, so a bogus type never previews as accepted.
static func check(world: WorldState, command: Dictionary) -> Dictionary:
	match command["type"]:
		"noop":
			return {}
		"dig", "chop", "forage", "till", "sow", "mine":
			var target_check := check_target_job_command(world, command)
			if not target_check.is_empty():
				return target_check
			return check_job_submission(command)
		"complete_job", "cancel_job", "fail_job", "invalidate_job":
			return check_terminal_job_command(world, command)
		"place_object":
			return check_place_object_command(world, command)
		"remove_object":
			return check_remove_object_command(world, command)
		"set_labour":
			return check_set_labour_command(world, command)
		"set_faction":
			return check_set_faction_command(world, command)
		"spawn_incident":
			return check_spawn_incident_command(world, command)
		"zone_add":
			return check_zone_add_command(world, command)
		"zone_remove":
			return check_zone_remove_command(world, command)
		"area_order":
			# Previews acceptance of the order itself; each expanded tile is
			# judged later by its own command (commands/area_orders.gd).
			return AreaOrders.check(command["payload"], world.get_map_width(), world.get_map_height())
		_:
			return {"reason": "unknown_command_type", "params": {"detail": "unknown_command_type", "type": command["type"]}}

## dig/chop/forage/till/sow target and assignee/faction rules -- mirrors
## OrderHandler.apply_job_command()'s own target-validation branch exactly.
static func check_target_job_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var type: String = command["type"]
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("priority", 1)) != TYPE_INT
			or typeof(payload.get("assignee", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "params": {"detail": "job_order_payload", "type": type}}
	var target := Vector2i(payload["x"], payload["y"])
	if target.x < 0 or target.x >= world.get_map_width() or target.y < 0 or target.y >= world.get_map_height():
		return {"reason": "invalid_target", "params": {"detail": "target_outside_map"}}
	if type == "forage":
		# forage's target is a berry_bush object, not a tile kind like dig/chop.
		if world.get_object(target.x, target.y) != "berry_bush":
			return {"reason": "invalid_target", "params": {"detail": "target_not_berry_bush"}}
	elif type == "till":
		if (world.get_tile(target.x, target.y) != WorldState.TILE_SOIL
				or not bool(world.passability(target.x, target.y)["passable"])):
			return {"reason": "invalid_target", "params": {"detail": "target_not_soil"}}
	elif type == "sow":
		if world.get_tile(target.x, target.y) != WorldState.TILE_PLOWED_SOIL:
			return {"reason": "invalid_target", "params": {"detail": "target_not_plowed_soil"}}
		if not world._has_item_of_kind("seed"):
			return {"reason": "blocked_missing_input", "params": {"detail": "missing_seed"}}
	elif type == "mine":
		# Rock, like a tree, is impassable -- no passability check (chop's shape, not dig's).
		if world.get_tile(target.x, target.y) != WorldState.TILE_ROCK:
			return {"reason": "invalid_target", "params": {"detail": "target_not_rock"}}
	else:
		var expected_tile := WorldState.TILE_SOIL if type == "dig" else WorldState.TILE_TREE
		var target_detail := "target_not_soil" if type == "dig" else "target_not_tree"
		if (world.get_tile(target.x, target.y) != expected_tile
				or (type == "dig" and not bool(world.passability(target.x, target.y)["passable"]))):
			return {"reason": "invalid_target", "params": {"detail": target_detail}}
	# assignee (F3), dig/chop/forage/mine only.
	if type in ["dig", "chop", "forage", "mine"]:
		var assignee := String(payload.get("assignee", ""))
		if not assignee.is_empty():
			var assigned_actor := world._find_colonist(assignee)
			if assigned_actor.is_empty():
				return {"reason": "invalid_target", "params": {"detail": "unknown_assignee", "assignee": assignee}}
			var assignee_faction := String(assigned_actor.get("factionId", "colony"))
			if not world._passability.faction_may_be_ordered(assignee_faction):
				return {"reason": WorldState.REASON_NOT_ORDERED_BY_PLAYER, "params": {"detail": "assignee_not_orderable", "assignee": assignee}}
	return {}

## Predicts JobQueue.submit_dig()'s rejection, for preview() only: apply() submits anyway so
## JobQueue emits its own job_rejected event and sequence draw.
static func check_job_submission(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var target := Vector2i(payload["x"], payload["y"])
	var priority: int = payload.get("priority", 1)
	var submission_check := JobQueue.check_submission(target, priority)
	if submission_check.is_empty():
		return {}
	return {"reason": submission_check["reason"], "params": {"remedy": submission_check["remedy"]}}

## The terminal-command rule through JobQueue.check_terminal(), for preview() only (never
## _reject(), which mutates). apply() goes through _finish_job() so a rejection still emits
## the job_rejected + command_rejected pair.
static func check_terminal_job_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("job_id")) != TYPE_STRING or String(payload["job_id"]).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "missing_job_id"}}
	var active_only: bool = command["type"] == "complete_job"
	var terminal_check := world._scheduler.queue.check_terminal(String(payload["job_id"]), active_only)
	if terminal_check.is_empty():
		return {}
	return {"reason": terminal_check["reason"], "params": {"remedy": terminal_check["remedy"]}}

## place_object's rule, for apply() and preview(). Deliberately looser than build's
## terrain rule: this is the debug/map-gen path (tests place objects on rock).
static func check_place_object_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("kind")) != TYPE_STRING or String(payload.get("kind")).is_empty()
			or typeof(payload.get("orientation", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "params": {"detail": "place_object_payload"}}
	var kind: String = payload["kind"]
	if not world._object_definitions.has(kind):
		return {"reason": "invalid_payload", "params": {"detail": "unknown_object_kind", "kind": kind}}
	var orientation := String(payload.get("orientation", ""))
	if not orientation.is_empty() and orientation != "horizontal" and orientation != "vertical":
		return {"reason": "invalid_payload", "params": {"detail": "invalid_orientation"}}
	var origin := Vector2i(int(payload["x"]), int(payload["y"]))
	for tile in world._object_table.object_footprint_tiles(kind, origin, orientation):
		if (tile.x < 0 or tile.x >= world._tile_grid.width or tile.y < 0 or tile.y >= world._tile_grid.height
				or world._colonist_at(tile.x, tile.y)
				or not world.get_object(tile.x, tile.y).is_empty()
				or world.get_tile(tile.x, tile.y) == WorldState.TILE_TREE
				or world.get_tile(tile.x, tile.y) == WorldState.TILE_WATER):
			return {"reason": "invalid_target", "params": {"detail": "place_object_blocked"}}
	return {}

## cancel_site {x, y} rule, run by apply() (ConstructionHandler) and preview().
## Not dispatched by check(): preview() calls it directly.
static func check_cancel_site_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	for key in payload.keys():
		if key != "x" and key != "y":
			return {"reason": "invalid_payload", "params": {"detail": "cancel_site_extra_field", "field": str(key)}}
	if typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT:
		return {"reason": "invalid_payload", "params": {"detail": "cancel_site_payload"}}
	if world._construction.construction_site_id_at(int(payload["x"]), int(payload["y"])).is_empty():
		return {"reason": "invalid_target", "params": {"detail": "no_construction_site"}}
	return {}

## remove_object target rule -- mirrors ConstructionHandler.apply_remove_object_command().
static func check_remove_object_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT:
		return {"reason": "invalid_payload", "params": {"detail": "remove_object_payload"}}
	var target := Vector2i(payload["x"], payload["y"])
	if (target.x < 0 or target.x >= world.get_map_width() or target.y < 0 or target.y >= world.get_map_height()
			or world.get_object(target.x, target.y).is_empty()):
		return {"reason": "invalid_target", "params": {"detail": "no_object_at_target"}}
	return {}

## zone_add rectangle rules -- mirrors ZoneHandler.apply_zone_add_command().
static func check_zone_add_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("width")) != TYPE_INT or typeof(payload.get("height")) != TYPE_INT
			or typeof(payload.get("kind", "stockpile")) != TYPE_STRING or typeof(payload.get("crop", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "params": {"detail": "zone_add_payload"}}
	# F1: a farm zone names a crops.json id; a stockpile names none.
	var zone_kind: String = payload.get("kind", "stockpile")
	var crop: String = payload.get("crop", "")
	if zone_kind not in ["stockpile", "farm"] or (zone_kind == "farm") == crop.is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "zone_add_payload"}}
	if zone_kind == "farm" and world._content.get_entry("crops", crop).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "unknown_crop", "crop": crop}}
	var x: int = payload["x"]
	var y: int = payload["y"]
	var width: int = payload["width"]
	var height: int = payload["height"]
	if (width < 1 or height < 1 or x < 0 or y < 0
			or x + width > world.get_map_width() or y + height > world.get_map_height()
			or world._zone_table.overlaps(x, y, width, height)):
		return {"reason": "invalid_target", "params": {"detail": "zone_rect_invalid"}}
	return {}

## zone_remove id rule -- mirrors ZoneHandler.apply_zone_remove_command().
static func check_zone_remove_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("id")) != TYPE_STRING or String(payload.get("id")).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "zone_remove_payload"}}
	if not world._zone_table.zones.has(String(payload["id"])):
		return {"reason": "invalid_target", "params": {"detail": "unknown_zone", "id": payload["id"]}}
	return {}

## set_labour payload/target rule -- mirrors ActorHandler.apply_set_labour_command().
static func check_set_labour_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("colonist")) != TYPE_STRING or String(payload.get("colonist")).is_empty()
			or typeof(payload.get("kind")) != TYPE_STRING or typeof(payload.get("level")) != TYPE_INT):
		return {"reason": "invalid_payload", "params": {"detail": "set_labour_payload"}}
	var kind: String = payload["kind"]
	var level: int = payload["level"]
	var worker_tunables: Dictionary = world._content.get_entry("actors", "colonist").get("tunables", {}).get("worker", {})
	if not WorldState.WorkerType.is_valid_labour_value(worker_tunables, kind, level):
		return {"reason": "invalid_payload", "params": {"detail": "labour_value_out_of_range",
			"kinds": str(WorldState.LABOUR_KINDS), "min": WorldState.LABOUR_MIN, "max": WorldState.LABOUR_MAX}}
	if world._find_colonist(String(payload["colonist"])).is_empty():
		return {"reason": "invalid_target", "params": {"detail": "unknown_colonist", "colonist": payload["colonist"]}}
	return {}

## set_faction payload/target rule -- mirrors ActorHandler.apply_set_faction_command().
static func check_set_faction_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("target")) != TYPE_STRING or String(payload.get("target")).is_empty()
			or typeof(payload.get("faction_id")) != TYPE_STRING):
		return {"reason": "invalid_payload", "params": {"detail": "set_faction_payload"}}
	var faction_id: String = payload["faction_id"]
	if world._content.get_entry("factions", faction_id).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "unknown_faction", "faction_id": faction_id}}
	if world._find_colonist(String(payload["target"])).is_empty():
		return {"reason": "invalid_target", "params": {"detail": "unknown_actor", "target": payload["target"]}}
	return {}

## spawn_incident payload/enablement rule -- mirrors IncidentHandler.apply_spawn_incident_command().
static func check_spawn_incident_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("id")) != TYPE_STRING or String(payload.get("id")).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "spawn_incident_payload"}}
	var incident_id: String = payload["id"]
	if world._content.get_entry("incidents", incident_id).is_empty():
		return {"reason": "invalid_payload", "params": {"detail": "unknown_incident", "incident_id": incident_id}}
	if not world._incidents.is_enabled():
		return {"reason": "invalid_target", "params": {"detail": "incidents_disabled"}}
	return {}
