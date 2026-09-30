extends SceneTree

## WorldState.preview(): a read-only dry run of apply()'s own rules, backed by
## game/scripts/core/commands/command_checks.gd's CommandChecks -- the same check apply()'s
## own handlers consult before mutating, so preview() can never disagree with apply(). Proves,
## per command type (dig/chop/forage/till/sow, place_object, remove_object, zone_add/
## zone_remove, cancel_job), both an accepted and a rejected case: preview()["ok"] equals
## apply()["ok"] immediately after (nothing changed state in between, so this is exactly "on a
## fresh copy"), the same rejection reason on a rejection, and state_hash() unchanged by
## preview() itself. Also proves the ~390ms StateCodec round trip is gone from the hover path
## (boot.gd's own _preview_validity()) and that previewing a 256x256 world's 12x12 hover
## rectangle (144 commands) is fast.

const WorldStateType = preload("res://scripts/core/world_state.gd")

const TICK := 0

var _failed := false

func _init() -> void:
	_check_dig_accepted_and_rejected_cases()
	_check_chop_accepted_and_rejected()
	_check_forage_accepted_and_non_bush_rejected()
	_check_till_accepted_and_rejected()
	_check_sow_accepted_and_missing_seed_rejected()
	_check_mine_accepted_and_rejected()
	_check_place_object_accepted_and_occupied_rejected()
	_check_remove_object_accepted_and_rejected()
	_check_zone_add_accepted_and_overlap_rejected()
	_check_zone_remove_accepted_and_unknown_rejected()
	_check_cancel_job_accepted_and_unknown_rejected()
	_check_terminal_job_already_terminal_and_not_active()
	_check_apply_terminal_rejection_still_emits_queue_and_command_events()
	_check_job_priority_range_rejected()
	_check_set_labour_accepted_and_rejected()
	_check_set_faction_accepted_and_rejected()
	_check_spawn_incident_accepted_and_rejected()
	_check_unknown_command_type_rejected()
	_check_malformed_envelope_with_valid_actor_purity()
	_check_preview_performance_256()
	_check_boot_preview_path_has_no_state_codec()

	if _failed:
		quit(1)
		return
	print("test_command_preview: PASS")
	quit(0)

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

## One colonist at (0,0) on an all-floor map, mirroring test_farming_content.gd's own
## _single_colonist_world() -- no "needs" key, so no need job can ever fire mid-test.
func _single_colonist_world(seed_value: int) -> WorldStateType:
	var world := WorldStateType.new(seed_value, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}})
	return world

## Core assertion shared by every case below: preview() must not move state_hash() or append any
## event/advance _event_sequence -- even repeated (a rejected preview must never mutate the
## live event log) -- and calling apply() immediately afterward (nothing else
## touched the world in between, so this is exactly "a fresh copy") must agree with preview()'s
## own ok/reason.
func _check_preview_matches_apply(world: WorldStateType, command: Dictionary, description: String) -> void:
	var hash_before := world.state_hash()
	var events_before: int = world.get_events().size()
	var sequence_before: int = world._event_sequence
	var preview_result: Dictionary = world.preview(command)
	world.preview(command)
	world.preview(command)
	_expect(world.state_hash() == hash_before, "%s: preview() must leave state_hash() unchanged" % description)
	_expect(world.get_events().size() == events_before,
		"%s: preview() (called 3x) must not append any event (before=%d after=%d)" % [description, events_before, world.get_events().size()])
	_expect(world._event_sequence == sequence_before,
		"%s: preview() (called 3x) must not advance _event_sequence (before=%d after=%d)" % [description, sequence_before, world._event_sequence])
	var apply_result: Dictionary = world.apply(command)
	_expect(preview_result.get("ok", false) == apply_result.get("ok", false),
		"%s: preview()['ok']=%s must equal apply()['ok']=%s" % [description, preview_result.get("ok", false), apply_result.get("ok", false)])
	if not apply_result.get("ok", true):
		var preview_reason := String(preview_result.get("rejection", {}).get("reason", ""))
		var apply_reason := String(apply_result.get("rejection", {}).get("reason", ""))
		_expect(preview_reason == apply_reason,
			"%s: rejection reason must match, preview=%s apply=%s" % [description, preview_reason, apply_reason])

func _job_command(world: WorldStateType, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": kind, "payload": payload}

func _check_dig_accepted_and_rejected_cases() -> void:
	var world := _single_colonist_world(346001)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	_check_preview_matches_apply(world, _job_command(world, "dig_accepted", "dig", {"x": 2, "y": 0, "priority": 1}),
		"dig on a passable soil tile")

	var oob := _single_colonist_world(346002)
	_check_preview_matches_apply(oob, _job_command(oob, "dig_oob", "dig", {"x": -1, "y": 0, "priority": 1}),
		"dig out of bounds")

	var wrong_kind := _single_colonist_world(346003)
	_check_preview_matches_apply(wrong_kind, _job_command(wrong_kind, "dig_wrong_kind", "dig", {"x": 2, "y": 0, "priority": 1}),
		"dig on a non-soil (floor) tile")

	var impassable := _single_colonist_world(346004)
	impassable._tiles[impassable._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	impassable._set_object(2, 0, "wooden_wall")
	_check_preview_matches_apply(impassable, _job_command(impassable, "dig_impassable", "dig", {"x": 2, "y": 0, "priority": 1}),
		"dig on an impassable (wall-covered) soil tile")

	var unknown_assignee := _single_colonist_world(346005)
	unknown_assignee._tiles[unknown_assignee._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	_check_preview_matches_apply(unknown_assignee,
		_job_command(unknown_assignee, "dig_unknown_assignee", "dig", {"x": 2, "y": 0, "priority": 1, "assignee": "no_such_colonist"}),
		"dig naming an unknown assignee")

func _check_chop_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346010)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TREE
	_check_preview_matches_apply(world, _job_command(world, "chop_accepted", "chop", {"x": 2, "y": 0, "priority": 1}),
		"chop on a tree tile")

	var wrong_kind := _single_colonist_world(346011)
	_check_preview_matches_apply(wrong_kind, _job_command(wrong_kind, "chop_wrong_kind", "chop", {"x": 2, "y": 0, "priority": 1}),
		"chop on a non-tree (floor) tile")

func _check_forage_accepted_and_non_bush_rejected() -> void:
	var world := _single_colonist_world(346020)
	world._set_object(2, 0, "berry_bush")
	_check_preview_matches_apply(world, _job_command(world, "forage_accepted", "forage", {"x": 2, "y": 0, "priority": 1}),
		"forage on a berry_bush object")

	var non_bush := _single_colonist_world(346021)
	_check_preview_matches_apply(non_bush, _job_command(non_bush, "forage_non_bush", "forage", {"x": 2, "y": 0, "priority": 1}),
		"forage on a tile with no berry_bush")

func _check_till_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346030)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	_check_preview_matches_apply(world, _job_command(world, "till_accepted", "till", {"x": 2, "y": 0, "priority": 1}),
		"till on a passable soil tile")

	var wrong_kind := _single_colonist_world(346031)
	_check_preview_matches_apply(wrong_kind, _job_command(wrong_kind, "till_wrong_kind", "till", {"x": 2, "y": 0, "priority": 1}),
		"till on a non-soil (floor) tile")

func _check_sow_accepted_and_missing_seed_rejected() -> void:
	var world := _single_colonist_world(346040)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_PLOWED_SOIL
	world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
	world._next_item_id = 2
	_check_preview_matches_apply(world, _job_command(world, "sow_accepted", "sow", {"x": 2, "y": 0, "priority": 1}),
		"sow on a plowed_soil tile with a seed available")

	var missing_seed := _single_colonist_world(346041)
	missing_seed._tiles[missing_seed._tile_index(2, 0)] = WorldStateType.TILE_PLOWED_SOIL
	_check_preview_matches_apply(missing_seed, _job_command(missing_seed, "sow_missing_seed", "sow", {"x": 2, "y": 0, "priority": 1}),
		"sow with no seed anywhere")

## Mine's own target/assignee validation moved into
## CommandChecks.check_target_job_command()/check(), so preview() must
## agree with apply() the same way dig/chop/forage/till/sow already do -- a valid rock target,
## a non-rock target, an unknown assignee and a refused (non-colony faction) assignee.
func _check_mine_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346042)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	_check_preview_matches_apply(world, _job_command(world, "mine_accepted", "mine", {"x": 2, "y": 0, "priority": 1}),
		"mine on a rock tile")

	var wrong_kind := _single_colonist_world(346043)
	_check_preview_matches_apply(wrong_kind, _job_command(wrong_kind, "mine_wrong_kind", "mine", {"x": 2, "y": 0, "priority": 1}),
		"mine on a non-rock (floor) tile")

	var unknown_assignee := _single_colonist_world(346044)
	unknown_assignee._tiles[unknown_assignee._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	_check_preview_matches_apply(unknown_assignee,
		_job_command(unknown_assignee, "mine_unknown_assignee", "mine", {"x": 2, "y": 0, "priority": 1, "assignee": "no_such_colonist"}),
		"mine naming an unknown assignee")

	var refused_assignee := _single_colonist_world(346045)
	refused_assignee._tiles[refused_assignee._tile_index(2, 0)] = WorldStateType.TILE_ROCK
	var raider_id: String = refused_assignee.get_colonists()[0]["id"]
	var set_faction_result: Dictionary = refused_assignee.apply({
		"actor": "test", "command_id": "mine_set_raider_faction", "tick": refused_assignee.get_tick(),
		"type": "set_faction", "payload": {"target": raider_id, "faction_id": "raiders"},
	})
	_expect(set_faction_result.get("ok", false), "set_faction to raiders must be accepted")
	_check_preview_matches_apply(refused_assignee,
		_job_command(refused_assignee, "mine_refused_assignee", "mine", {"x": 2, "y": 0, "priority": 1, "assignee": raider_id}),
		"mine assigned to a non-colony (raiders) actor")

func _place_object_command(world: WorldStateType, command_id: String, x: int, y: int, kind: String) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "place_object", "payload": {"x": x, "y": y, "kind": kind}}

func _remove_object_command(world: WorldStateType, command_id: String, x: int, y: int) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "remove_object", "payload": {"x": x, "y": y}}

func _check_place_object_accepted_and_occupied_rejected() -> void:
	var world := _single_colonist_world(346050)
	_check_preview_matches_apply(world, _place_object_command(world, "place_accepted", 2, 0, "wooden_wall"),
		"place_object on an empty floor tile")

	var occupied := _single_colonist_world(346051)
	occupied._set_object(2, 0, "wooden_wall")
	_check_preview_matches_apply(occupied, _place_object_command(occupied, "place_occupied", 2, 0, "wooden_wall"),
		"place_object on an already-occupied tile")

func _check_remove_object_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346060)
	world._set_object(2, 0, "wooden_wall")
	_check_preview_matches_apply(world, _remove_object_command(world, "remove_accepted", 2, 0),
		"remove_object on a tile holding an object")

	var empty := _single_colonist_world(346061)
	_check_preview_matches_apply(empty, _remove_object_command(empty, "remove_empty", 2, 0),
		"remove_object on a tile with no object")

func _zone_add_command(world: WorldStateType, command_id: String, x: int, y: int, width: int, height: int) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "zone_add", "payload": {"x": x, "y": y, "width": width, "height": height}}

func _zone_remove_command(world: WorldStateType, command_id: String, id: String) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "zone_remove", "payload": {"id": id}}

func _check_zone_add_accepted_and_overlap_rejected() -> void:
	var world := _single_colonist_world(346070)
	_check_preview_matches_apply(world, _zone_add_command(world, "zone_add_accepted", 10, 10, 3, 3),
		"zone_add on an empty rectangle")

	var overlap := _single_colonist_world(346071)
	var setup: Dictionary = overlap.apply(_zone_add_command(overlap, "zone_add_setup", 10, 10, 3, 3))
	_expect(setup.get("ok", false), "setup zone_add for the overlap case must be accepted")
	_check_preview_matches_apply(overlap, _zone_add_command(overlap, "zone_add_overlap", 11, 11, 3, 3),
		"zone_add overlapping an existing zone")

func _check_zone_remove_accepted_and_unknown_rejected() -> void:
	var world := _single_colonist_world(346080)
	var setup: Dictionary = world.apply(_zone_add_command(world, "zone_remove_setup", 10, 10, 2, 2))
	_expect(setup.get("ok", false), "setup zone_add for the zone_remove case must be accepted")
	_check_preview_matches_apply(world, _zone_remove_command(world, "zone_remove_accepted", String(setup["zone_id"])),
		"zone_remove of an existing zone")

	var unknown := _single_colonist_world(346081)
	_check_preview_matches_apply(unknown, _zone_remove_command(unknown, "zone_remove_unknown", "zone_999"),
		"zone_remove of an unknown zone id")

func _check_cancel_job_accepted_and_unknown_rejected() -> void:
	var world := _single_colonist_world(346090)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var setup: Dictionary = world.apply(_job_command(world, "cancel_setup", "dig", {"x": 2, "y": 0, "priority": 1}))
	_expect(setup.get("ok", false), "setup dig for the cancel_job case must be accepted")
	_check_preview_matches_apply(world,
		{"actor": "player", "command_id": "cancel_accepted", "tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": String(setup["job_id"])}},
		"cancel_job of an existing queued/active job")

	var unknown := _single_colonist_world(346091)
	_check_preview_matches_apply(unknown,
		{"actor": "player", "command_id": "cancel_unknown", "tick": unknown.get_tick(), "type": "cancel_job", "payload": {"job_id": "job_999999"}},
		"cancel_job of an unknown job")

## Two more terminal-command rejections check_terminal_job_command()
## must predict correctly -- an already-terminal job (cancelled twice) and complete_job on a
## job that is still queued (never activated by a tick).
func _check_terminal_job_already_terminal_and_not_active() -> void:
	var world := _single_colonist_world(346160)
	world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var setup: Dictionary = world.apply(_job_command(world, "already_terminal_setup", "dig", {"x": 2, "y": 0, "priority": 1}))
	_expect(setup.get("ok", false), "setup dig for the already-terminal case must be accepted")
	var job_id := String(setup["job_id"])
	var first_cancel := world.apply({"actor": "player", "command_id": "already_terminal_cancel_1", "tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}})
	_expect(first_cancel.get("ok", false), "the first cancel_job must be accepted")
	_check_preview_matches_apply(world,
		{"actor": "player", "command_id": "already_terminal_cancel_2", "tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": job_id}},
		"cancel_job of an already-terminal (cancelled) job")

	var queued_world := _single_colonist_world(346161)
	queued_world._tiles[queued_world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
	var queued_setup: Dictionary = queued_world.apply(_job_command(queued_world, "not_active_setup", "dig", {"x": 2, "y": 0, "priority": 1}))
	_expect(queued_setup.get("ok", false), "setup dig for the not-active case must be accepted")
	_expect(String(queued_world._get_job(String(queued_setup["job_id"]))["status"]) == "queued",
		"the freshly submitted job must still be queued (no tick() has run yet) for this case to be meaningful")
	_check_preview_matches_apply(queued_world,
		{"actor": "player", "command_id": "not_active_complete", "tick": queued_world.get_tick(), "type": "complete_job", "payload": {"job_id": String(queued_setup["job_id"])}},
		"complete_job of a still-queued (not active) job")

## apply()'s terminal branch must keep going through JobQueue._finish()
## itself for a rejected terminal command (unknown job here) -- it must still emit both the
## queue's own job_rejected event (JobQueue._reject()) and WorldState's command_rejected event.
## check_terminal_job_command() exists to answer preview() without either side effect; it must never
## replace apply()'s own event-producing path.
func _check_apply_terminal_rejection_still_emits_queue_and_command_events() -> void:
	var world := _single_colonist_world(346170)
	var events_before: int = world.get_events().size()
	var result := world.apply({"actor": "player", "command_id": "unknown_cancel_apply", "tick": world.get_tick(), "type": "cancel_job", "payload": {"job_id": "job_999999"}})
	_expect(not result.get("ok", true), "cancel_job of an unknown job must be rejected by apply()")
	var events_after: Array = world.get_events()
	_expect(events_after.size() == events_before + 2,
		"apply() rejecting an unknown terminal job must emit exactly 2 new events (job_rejected + command_rejected), got %d" % (events_after.size() - events_before))
	var new_types: Array = []
	for i in range(events_before, events_after.size()):
		new_types.append(String(events_after[i]["type"]))
	_expect(new_types.has("job_rejected") and new_types.has("command_rejected"),
		"apply()'s rejected terminal command must emit both job_rejected and command_rejected, got %s" % [new_types])

## check_target_job_command() must reject a priority outside
## JobQueue.Priority's range even when the target itself is otherwise valid, for every job type
## -- previously only priority 1 (NORMAL) was ever exercised, so an out-of-range priority
## silently previewed ok while apply() went on to reject it via JobQueue.submit_dig().
##
## An unsupported priority on an otherwise-valid target must still reach
## JobQueue.submit_dig() through WorldState._apply_job_command()'s ordinary submit() call, so
## it still produces JobQueue's own job_rejected event and advances JobQueue's sequence counter, not
## just an early WorldState-level rejection that happens to carry the same reason.
## CommandChecks.check_job_submission() (preview()'s check() dispatcher only) predicts this outcome
## without ever causing it.
func _check_job_priority_range_rejected() -> void:
	var base_seed := 346180
	for job_type in ["dig", "chop", "forage", "till", "sow", "mine"]:
		for priority in [-1, 3]:
			var world := _single_colonist_world(base_seed)
			base_seed += 1
			match job_type:
				"dig", "till":
					world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_SOIL
				"chop":
					world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_TREE
				"mine":
					world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_ROCK
				"forage":
					world._set_object(2, 0, "berry_bush")
				"sow":
					world._tiles[world._tile_index(2, 0)] = WorldStateType.TILE_PLOWED_SOIL
					world._items["item_seed_1"] = {"id": "item_seed_1", "x": 5, "y": 5, "kind": "seed", "count": 1}
					world._next_item_id = 2
			var description := "%s with a valid target but unsupported priority %d" % [job_type, priority]
			var sequence_before: int = world._scheduler.queue.get_sequence()
			_check_preview_matches_apply(world,
				_job_command(world, "%s_priority_%d" % [job_type, priority], job_type, {"x": 2, "y": 0, "priority": priority}),
				description)
			var saw_job_rejected := false
			for event in world.get_events():
				if String(event["type"]) == "job_rejected":
					saw_job_rejected = true
					break
			_expect(saw_job_rejected,
				"%s: apply() rejecting an unsupported priority must still emit JobQueue's own job_rejected event" % description)
			_expect(world._scheduler.queue.get_sequence() > sequence_before,
				"%s: apply() rejecting an unsupported priority must still advance JobQueue's sequence counter (before=%d after=%d)" % [description, sequence_before, world._scheduler.queue.get_sequence()])

func _set_labour_command(world: WorldStateType, command_id: String, colonist, kind, level) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "set_labour", "payload": {"colonist": colonist, "kind": kind, "level": level}}

## set_labour previously had no check_*() function at all, so
## CommandChecks.check()'s dispatch fallback silently approved it in preview() regardless of
## apply()'s own validation.
func _check_set_labour_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346190)
	_check_preview_matches_apply(world, _set_labour_command(world, "labour_accepted", "colonist_0", "mine", 2),
		"set_labour with a valid colonist/kind/level")

	var invalid_level := _single_colonist_world(346191)
	_check_preview_matches_apply(invalid_level, _set_labour_command(invalid_level, "labour_invalid_level", "colonist_0", "mine", 9),
		"set_labour with an out-of-range level")

func _set_faction_command(world: WorldStateType, command_id: String, target, faction_id) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "set_faction", "payload": {"target": target, "faction_id": faction_id}}

## Same gap as set_labour -- set_faction had no check_*() function.
func _check_set_faction_accepted_and_rejected() -> void:
	var world := _single_colonist_world(346200)
	_check_preview_matches_apply(world, _set_faction_command(world, "faction_accepted", "colonist_0", "wildlife"),
		"set_faction to a known faction")

	var unknown_faction := _single_colonist_world(346201)
	_check_preview_matches_apply(unknown_faction, _set_faction_command(unknown_faction, "faction_unknown", "colonist_0", "no_such_faction"),
		"set_faction to an unknown faction")

func _spawn_incident_command(world: WorldStateType, command_id: String, id: String) -> Dictionary:
	return {"actor": "player", "command_id": command_id, "tick": world.get_tick(), "type": "spawn_incident", "payload": {"id": id}}

## Same gap as set_labour/set_faction -- spawn_incident had no
## check_*() function, so preview() never predicted the "incidents disabled" rejection.
func _check_spawn_incident_accepted_and_rejected() -> void:
	var enabled := WorldStateType.new(346210, 10, WorldStateType.MAP_WIDTH, WorldStateType.MAP_HEIGHT, true)
	_check_preview_matches_apply(enabled, _spawn_incident_command(enabled, "incident_accepted", "wildlife_wander"),
		"spawn_incident with incidents enabled")

	var disabled := _single_colonist_world(346211)
	_check_preview_matches_apply(disabled, _spawn_incident_command(disabled, "incident_disabled", "wildlife_wander"),
		"spawn_incident with incidents disabled")

## CommandChecks.check()'s dispatch fallback used to return {} (ok) for
## any unmatched type, so a bogus command type previewed as accepted while apply() rejects it
## unknown_command_type.
func _check_unknown_command_type_rejected() -> void:
	var world := _single_colonist_world(346220)
	_check_preview_matches_apply(world,
		{"actor": "player", "command_id": "bogus_type", "tick": world.get_tick(), "type": "bogus", "payload": {}},
		"an unrecognized command type")

## A malformed envelope (missing command_id/tick/type/payload, or an
## invalid payload value type, or a tick mismatch) on an otherwise-valid actor is exactly the
## case that used to leak a command_rejected event and advance _event_sequence through
## _validate_command()'s own _rejection() calls; _check_preview_matches_apply() now asserts
## purity for every case it runs, so reusing it here covers the events/sequence assertion too.
func _check_malformed_envelope_with_valid_actor_purity() -> void:
	var missing_command_id := _single_colonist_world(346230)
	_check_preview_matches_apply(missing_command_id,
		{"actor": "player", "tick": missing_command_id.get_tick(), "type": "dig", "payload": {"x": 2, "y": 0, "priority": 1}},
		"envelope missing command_id, valid actor")

	var missing_tick := _single_colonist_world(346231)
	_check_preview_matches_apply(missing_tick,
		{"actor": "player", "command_id": "c1", "type": "dig", "payload": {"x": 2, "y": 0, "priority": 1}},
		"envelope missing tick, valid actor")

	var missing_type := _single_colonist_world(346232)
	_check_preview_matches_apply(missing_type,
		{"actor": "player", "command_id": "c1", "tick": missing_type.get_tick(), "payload": {"x": 2, "y": 0, "priority": 1}},
		"envelope missing type, valid actor")

	var missing_payload := _single_colonist_world(346233)
	_check_preview_matches_apply(missing_payload,
		{"actor": "player", "command_id": "c1", "tick": missing_payload.get_tick(), "type": "dig"},
		"envelope missing payload, valid actor")

	var invalid_payload_value := _single_colonist_world(346234)
	_check_preview_matches_apply(invalid_payload_value,
		{"actor": "player", "command_id": "c1", "tick": invalid_payload_value.get_tick(), "type": "dig", "payload": {"x": 2, "y": 0.5, "priority": 1}},
		"payload with a non-int/string value (float), valid actor")

	var tick_mismatch := _single_colonist_world(346235)
	_check_preview_matches_apply(tick_mismatch,
		{"actor": "player", "command_id": "c1", "tick": tick_mismatch.get_tick() + 1, "type": "dig", "payload": {"x": 2, "y": 0, "priority": 1}},
		"tick mismatch, valid actor")

## Goal: previewing a 12x12 hover rectangle (144 commands) on a 256x256 world must
## take under 5ms headless -- the old StateCodec.encode()/decode() round trip measured ~390ms
## per single-tile hover on the host.
const PREVIEW_BUDGET_USEC := 5000

func _check_preview_performance_256() -> void:
	var world := WorldStateType.new(42, 10, 256, 256)
	var commands: Array[Dictionary] = []
	for y in range(10, 22):
		for x in range(10, 22):
			commands.append(_job_command(world, "perf_dig_%d_%d" % [x, y], "dig", {"x": x, "y": y, "priority": 1}))
	_expect(commands.size() == 144, "the timed fixture must cover a 12x12 = 144-tile rectangle, got %d" % commands.size())
	var start := Time.get_ticks_usec()
	for command in commands:
		world.preview(command)
	var elapsed_usec := Time.get_ticks_usec() - start
	_expect(elapsed_usec < PREVIEW_BUDGET_USEC,
		"previewing a 12x12 rectangle (144 commands) on a 256x256 world must take under %d us, took %d us"
			% [PREVIEW_BUDGET_USEC, elapsed_usec])

## boot.gd's own hover-path function must call world.preview() instead of round-tripping
## through StateCodec.encode()/decode() -- proved by text-scanning _preview_validity()'s own
## function body rather than the whole file, since boot.gd still uses StateCodec for save/load.
func _check_boot_preview_path_has_no_state_codec() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/boot.gd")
	_expect(not source.is_empty(), "boot.gd must be readable")
	var start := source.find("func _preview_validity(")
	_expect(start != -1, "boot.gd must declare _preview_validity()")
	if start == -1:
		return
	var next_func := source.find("\nfunc ", start + 1)
	var body := source.substr(start, (next_func - start) if next_func != -1 else source.length() - start)
	_expect(not body.contains("StateCodec"),
		"_preview_validity() must contain no StateCodec reference on the preview path, got:\n%s" % body)
