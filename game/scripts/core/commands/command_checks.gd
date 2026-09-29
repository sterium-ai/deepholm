class_name CommandChecks
extends RefCounted

## Read-only pre-mutation rule set for WorldState.apply()'s job/place-object/remove-object/
## zone command handlers, extracted (issue #346) so WorldState.preview() can run the exact
## same rules a hover/drag preview or Play-mode cursor needs without mutating state or
## round-tripping the whole world through StateCodec.encode()/decode() (~390ms on a 256x256
## map). Every check function below mirrors its WorldState._apply_*_command() counterpart's
## own rejection order exactly and returns {} when the command may proceed, or
## {"reason": ..., "message": ...} when apply() would reject it -- never touches `world`'s
## state. Where the real rule lives in JobQueue (submission priority/target, terminal-transition
## status), this module calls JobQueue's own pure predicates (check_submission(), check_terminal(),
## game/scripts/core/jobs/job_queue.gd) rather than re-implementing them, so the rule stays in
## exactly one place (AGENTS.md "one work engine" applies here too): check_job_submission() is
## consulted by preview()'s check() dispatcher only -- WorldState._apply_job_command() always
## calls through to JobQueue.submit_dig() itself for a target-valid job command, exactly as it
## did before this task, so an unsupported priority still produces JobQueue's own job_rejected
## event and advances its sequence counter instead of being silently absorbed by an early
## WorldState-level rejection.
##
## Reaches into WorldState's own underscore-prefixed helpers/fields directly (_find_colonist,
## _has_item_of_kind, _faction_may_be_ordered, _colonist_at, _object_definitions,
## _zones, _zone_overlaps, _content, _incidents, _scheduler), the same convention
## game/scripts/core/persistence/state_codec.gd already uses for WorldState internals --
## GDScript's underscore prefix is a naming convention, not enforced access control, and this
## module is WorldState's own command-rule companion, not an external consumer.

## Dispatches command["type"] to its own check function. Every type apply() actually mutates
## through or rejects on dispatch has an entry: "noop" always previews ok (its own apply()
## handler never rejects once the envelope validates); an unrecognized type returns the exact
## "unknown_command_type" rejection apply()'s own dispatch fallback would produce, so a bogus
## type never previews as accepted.
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
		_:
			return {"reason": "unknown_command_type", "message": "No handler for command type '%s'." % command["type"]}

## dig/chop/forage/till/sow target and assignee/faction rules -- mirrors
## WorldState._apply_job_command()'s own target-validation branch exactly.
static func check_target_job_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var type: String = command["type"]
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("priority", 1)) != TYPE_INT
			or typeof(payload.get("assignee", "")) != TYPE_STRING):
		return {"reason": "invalid_payload", "message": "%s requires integer x, y and priority, and a string assignee when present." % type.capitalize()}
	var target := Vector2i(payload["x"], payload["y"])
	if target.x < 0 or target.x >= world.get_map_width() or target.y < 0 or target.y >= world.get_map_height():
		return {"reason": "invalid_target", "message": "Choose a tile within the map."}
	if type == "forage":
		# forage's target is a berry_bush object, not a tile kind like dig/chop.
		if world.get_object(target.x, target.y) != "berry_bush":
			return {"reason": "invalid_target", "message": "Choose a berry bush tile within the map."}
	elif type == "till":
		if (world.get_tile(target.x, target.y) != WorldState.TILE_SOIL
				or not bool(world.passability(target.x, target.y)["passable"])):
			return {"reason": "invalid_target", "message": "Choose a soil tile within the map."}
	elif type == "sow":
		if world.get_tile(target.x, target.y) != WorldState.TILE_PLOWED_SOIL:
			return {"reason": "invalid_target", "message": "Choose a plowed soil tile within the map."}
		if not world._has_item_of_kind("seed"):
			return {"reason": "blocked_missing_input", "message": "Produce or acquire a seed first."}
	elif type == "mine":
		# Rock, like a tree, is impassable -- no passability check (chop's shape, not dig's).
		if world.get_tile(target.x, target.y) != WorldState.TILE_ROCK:
			return {"reason": "invalid_target", "message": "Choose a rock tile within the map."}
	else:
		var expected_tile := WorldState.TILE_SOIL if type == "dig" else WorldState.TILE_TREE
		var target_message := "Choose a soil tile within the map." if type == "dig" else "Choose a tree tile within the map."
		if (world.get_tile(target.x, target.y) != expected_tile
				or (type == "dig" and not bool(world.passability(target.x, target.y)["passable"]))):
			return {"reason": "invalid_target", "message": target_message}
	# assignee (F3, issue #290), dig/chop/forage/mine only.
	if type in ["dig", "chop", "forage", "mine"]:
		var assignee := String(payload.get("assignee", ""))
		if not assignee.is_empty():
			var assigned_actor := world._find_colonist(assignee)
			if assigned_actor.is_empty():
				return {"reason": "invalid_target", "message": "Choose an existing actor id for assignee."}
			var assignee_faction := String(assigned_actor.get("factionId", "colony"))
			if not world._faction_may_be_ordered(assignee_faction):
				return {"reason": WorldState.REASON_NOT_ORDERED_BY_PLAYER, "message": "Choose an actor the player's faction may order."}
	return {}

## Predicts JobQueue.submit_dig()'s own priority/target rejection, for preview()'s check()
## dispatcher only (issue #346 round 2) -- see this file's module doc comment for why apply()
## deliberately does not consult this. check_target_job_command() above already proved the
## target/tile-kind/assignee rules pass by the time the dispatcher calls this.
static func check_job_submission(command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	var target := Vector2i(payload["x"], payload["y"])
	var priority: int = payload.get("priority", 1)
	var submission_check := JobQueue.check_submission(target, priority)
	if submission_check.is_empty():
		return {}
	return {"reason": submission_check["reason"], "message": submission_check["remedy"]}

## job_id lookup + status rule for complete_job/cancel_job/fail_job/invalidate_job, consulted by
## preview() only -- calls JobQueue.check_terminal() (game/scripts/core/jobs/job_queue.gd), the
## same pure predicate _finish() itself consults, so the rule lives in exactly one place. Never
## JobQueue._reject() itself, which mutates (appends a job_rejected event and advances JobQueue's
## own sequence counter) as a side effect preview() must never cause.
## WorldState._apply_job_command()'s own terminal branch does NOT call this: it keeps its
## pre-#346 shape (payload check only, then _finish_job()) so a rejected terminal command still
## produces the exact job_rejected + command_rejected event pair apply() has always emitted,
## through JobQueue._finish()'s own check_terminal() + _reject() call, not this one.
static func check_terminal_job_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("job_id")) != TYPE_STRING or String(payload["job_id"]).is_empty():
		return {"reason": "invalid_payload", "message": "A non-empty job_id is required."}
	var active_only: bool = command["type"] == "complete_job"
	var terminal_check := world._scheduler.queue.check_terminal(String(payload["job_id"]), active_only)
	if terminal_check.is_empty():
		return {}
	return {"reason": terminal_check["reason"], "message": terminal_check["remedy"]}

## place_object target rule (issue #405 round 3): delegates to
## WorldState._check_place_object_command(), the one footprint/orientation-aware
## implementation _apply_place_object_command() and preview() both already run
## (world_state.gd, around _check_place_object_command()'s own doc comment) --
## this module's own module doc comment already promises "the rule stays in
## exactly one place"; duplicating a second, single-tile-only copy here would
## have broken that promise and silently gone stale the moment footprint/
## orientation were added, exactly as round-2 review found. check() above still
## dispatches "place_object" here so a direct CommandChecks.check() caller gets
## the real, current rule too, not the pre-#405 single-tile shape.
static func check_place_object_command(world: WorldState, command: Dictionary) -> Dictionary:
	return world._check_place_object_command(command["payload"])

## remove_object target rule -- mirrors WorldState._apply_remove_object_command().
static func check_remove_object_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT:
		return {"reason": "invalid_payload", "message": "remove_object requires integer x and y."}
	var target := Vector2i(payload["x"], payload["y"])
	if (target.x < 0 or target.x >= world.get_map_width() or target.y < 0 or target.y >= world.get_map_height()
			or world.get_object(target.x, target.y).is_empty()):
		return {"reason": "invalid_target", "message": "Choose a tile that holds an object."}
	return {}

## zone_add rectangle rules -- mirrors WorldState._apply_zone_add_command().
static func check_zone_add_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("x")) != TYPE_INT or typeof(payload.get("y")) != TYPE_INT
			or typeof(payload.get("width")) != TYPE_INT or typeof(payload.get("height")) != TYPE_INT):
		return {"reason": "invalid_payload", "message": "zone_add requires integer x, y, width and height."}
	var x: int = payload["x"]
	var y: int = payload["y"]
	var width: int = payload["width"]
	var height: int = payload["height"]
	if (width < 1 or height < 1 or x < 0 or y < 0
			or x + width > world.get_map_width() or y + height > world.get_map_height()
			or world._zone_overlaps(x, y, width, height)):
		return {"reason": "invalid_target", "message": "Choose a non-degenerate, in-bounds rectangle that does not overlap an existing zone."}
	return {}

## zone_remove id rule -- mirrors WorldState._apply_zone_remove_command().
static func check_zone_remove_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("id")) != TYPE_STRING or String(payload.get("id")).is_empty():
		return {"reason": "invalid_payload", "message": "zone_remove requires a non-empty string id."}
	if not world._zones.has(String(payload["id"])):
		return {"reason": "invalid_target", "message": "Choose an existing zone id."}
	return {}

## set_labour payload/target rule -- mirrors WorldState._apply_set_labour_command().
static func check_set_labour_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("colonist")) != TYPE_STRING or String(payload.get("colonist")).is_empty()
			or typeof(payload.get("kind")) != TYPE_STRING or typeof(payload.get("level")) != TYPE_INT):
		return {"reason": "invalid_payload", "message": "set_labour requires a non-empty string colonist, a string kind and an integer level."}
	var kind: String = payload["kind"]
	var level: int = payload["level"]
	var worker_tunables: Dictionary = world._content.get_entry("actors", "colonist").get("tunables", {}).get("worker", {})
	if not WorldState.WorkerType.is_valid_labour_value(worker_tunables, kind, level):
		return {"reason": "invalid_payload", "message": "kind must be one of %s and level must be %d..%d." % [WorldState.LABOUR_KINDS, WorldState.LABOUR_MIN, WorldState.LABOUR_MAX]}
	if world._find_colonist(String(payload["colonist"])).is_empty():
		return {"reason": "invalid_target", "message": "Choose an existing colonist id."}
	return {}

## set_faction payload/target rule -- mirrors WorldState._apply_set_faction_command().
static func check_set_faction_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if (typeof(payload.get("target")) != TYPE_STRING or String(payload.get("target")).is_empty()
			or typeof(payload.get("faction_id")) != TYPE_STRING):
		return {"reason": "invalid_payload", "message": "set_faction requires a non-empty string target and a string faction_id."}
	var faction_id: String = payload["faction_id"]
	if world._content.get_entry("factions", faction_id).is_empty():
		return {"reason": "invalid_payload", "message": "Unknown faction '%s'." % faction_id}
	if world._find_colonist(String(payload["target"])).is_empty():
		return {"reason": "invalid_target", "message": "Choose an existing actor id."}
	return {}

## spawn_incident payload/enablement rule -- mirrors WorldState._apply_spawn_incident_command().
static func check_spawn_incident_command(world: WorldState, command: Dictionary) -> Dictionary:
	var payload: Dictionary = command["payload"]
	if typeof(payload.get("id")) != TYPE_STRING or String(payload.get("id")).is_empty():
		return {"reason": "invalid_payload", "message": "spawn_incident requires a non-empty string id."}
	var incident_id: String = payload["id"]
	if world._content.get_entry("incidents", incident_id).is_empty():
		return {"reason": "invalid_payload", "message": "Unknown incident '%s'." % incident_id}
	if not world._incidents.is_enabled():
		return {"reason": "invalid_target", "message": "Incidents are disabled for this world."}
	return {}
