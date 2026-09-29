extends SceneTree

## Issue #299 round 1 review: SaveIO's bounds check previously covered only
## entity/item/object/zone/tool-item positions. A hand-edited or corrupted
## save could still smuggle an out-of-bounds coordinate through a job
## target/cell, a scheduling queue entry, a pending route search, an
## assignment path, an entity's own in-flight route, a groundBerries entry,
## or a workProgress entry -- none of those were bounds-checked before this
## round. Each check below starts from one shared, fully valid 8x8 state
## (entity and object positions always valid) and corrupts exactly one
## coordinate family at a time, proving every family independently rejects
## an out-of-bounds coordinate without disturbing the others.

const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const WorldGeneratorType = preload("res://scripts/core/worldgen/world_generator.gd")

const MAP_WIDTH := 8
const MAP_HEIGHT := 8
const OUT_OF_BOUNDS := MAP_WIDTH # any x/y >= width or >= height is out of bounds

var _failed := false

func _init() -> void:
	_expect_valid_baseline()
	_check_rejects("jobs,0,target", func(state): (state["jobs"][0] as Dictionary)["target"] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("jobs,0,cell", func(state): (state["jobs"][0] as Dictionary)["cell"] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("scheduling.waiting,0,target", func(state): (state["scheduling"]["waiting"][0] as Dictionary)["target"] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("scheduling.activatedEntries.job_1.target", func(state): (state["scheduling"]["activatedEntries"]["job_1"] as Dictionary)["target"] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("scheduling.assignments.colonist_1.path,0", func(state): ((state["scheduling"]["assignments"]["colonist_1"] as Dictionary)["path"] as Array)[0] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("scheduling.pending.colonist_2.start", func(state): (state["scheduling"]["pending"]["colonist_2"] as Dictionary)["start"] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("scheduling.pending.colonist_2.candidates,0,target", func(state): ((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["candidates"] as Array)[0]["target"] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("scheduling.pending.colonist_2.route.path,0", func(state): (((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["route"] as Dictionary)["path"] as Array)[0] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("scheduling.pending.colonist_2.route.frontier,0", func(state): (((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["route"] as Dictionary)["frontier"] as Array)[0] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("scheduling.pending.colonist_2.route.visited,0", func(state): (((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["route"] as Dictionary)["visited"] as Array)[0] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("scheduling.pending.colonist_2.route.cameFrom,0.child", func(state): (((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["route"] as Dictionary)["cameFrom"] as Array)[0]["child"] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("scheduling.pending.colonist_2.route.start", func(state): (((state["scheduling"]["pending"]["colonist_2"] as Dictionary)["route"] as Dictionary))["start"] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("entities,0,route.path,0", func(state): (((state["entities"][0] as Dictionary)["route"] as Dictionary)["path"] as Array)[0] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("entities,0,route.rerouting.target", func(state): (((state["entities"][0] as Dictionary)["route"] as Dictionary)["rerouting"] as Dictionary)["target"] = _tile(0, OUT_OF_BOUNDS))
	_check_rejects("groundBerries,0,target", func(state): (state["groundBerries"][0] as Dictionary)["target"] = _tile(OUT_OF_BOUNDS, 0))
	_check_rejects("workProgress,0,target", func(state): (state["workProgress"][0] as Dictionary)["target"] = _tile(0, OUT_OF_BOUNDS))

	if _failed:
		quit(1)
		return
	print("test_save_bounds_validation: PASS")
	quit()

func _tile(x: int, y: int) -> Dictionary:
	return {"x": x, "y": y}

func _fail(message: String) -> void:
	push_error(message)
	_failed = true

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)

func _expect_valid_baseline() -> void:
	var validation := SaveIOType._validate_state(_base_state())
	_expect(validation["ok"], "the shared baseline fixture must itself be valid before any corruption: %s" % validation.get("message", ""))

## Applies `corrupt` to a fresh deep copy of the shared baseline state, then
## asserts SaveIO rejects it with a typed schema_error while every entity and
## object position in the fixture remains valid and untouched -- proving the
## corruption is isolated to the one coordinate family each check targets.
func _check_rejects(label: String, corrupt: Callable) -> void:
	var state := _base_state()
	corrupt.call(state)
	var result := SaveIOType._validate_state(state)
	_expect(not result["ok"], "corrupting %s must be rejected" % label)
	_expect(result.get("code", "") == "schema_error", "corrupting %s must be a typed schema_error, got %s" % [label, result])

## One shared, fully valid, current-schema-shaped 8x8 state exercising every
## nested coordinate family SaveIO now bounds-checks: a job with a target and
## a cell, a scheduling.waiting queue entry, an activatedEntries entry, an
## assignment with a path, a pending route search (candidates/start/route
## with frontier/visited/cameFrom/path all populated), one entity with both
## an active route and an in-flight reroute search, one groundBerries entry,
## and one workProgress entry. Entity ("colonist_1" at (0,0)) and object
## ("wall" at (2,2)) positions are always valid and never touched by any
## _check_rejects() corruption above.
func _base_state() -> Dictionary:
	var route_state := {
		"start": _tile(0, 0), "target": _tile(1, 1), "status": "searching",
		"frontier": [_tile(1, 0)], "visited": [_tile(0, 0)],
		"cameFrom": [{"child": _tile(1, 0), "parent": _tile(0, 0)}],
		"path": [_tile(0, 0)], "expansions": 1, "resumeCalls": 1,
	}
	var queue_entry := {"id": "job_1", "target": _tile(1, 1), "base": 0, "submittedTick": 0, "ordinal": 0, "restrictTo": ""}
	var entity_route := {
		"jobId": "job_1", "path": [_tile(0, 0), _tile(1, 1)], "step": 0, "moveTicksRemaining": 0,
		"rerouting": route_state.duplicate(true),
	}
	return {
		"schemaVersion": StateCodecType.SCHEMA_VERSION, "contentVersion": StateCodecType.content_version(),
		"seed": 1, "tick": 0, "epoch": 0,
		"map": {
			"width": MAP_WIDTH, "height": MAP_HEIGHT,
			"tiles": _flat_soil_tiles(), "generatorVersion": WorldGeneratorType.GENERATOR_VERSION,
		},
		"entities": [{
			"id": "colonist_1", "kind": "colonist", "x": 0, "y": 0, "factionId": "colony",
			"health": {"hp": 10, "maxHp": 10, "dead": false},
			"needs": {"food": 100, "water": 100, "rest": 100},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": entity_route, "work": null, "hands": [], "trapped": null,
		}],
		"inventory": {},
		"jobs": [{
			"id": "job_1", "kind": "dig", "status": "queued", "priority": 1, "target": _tile(1, 1),
			"reason": "", "remedy": "", "blockingJobId": "", "itemId": "", "cell": _tile(2, 1),
			"retryAt": 0, "backoffTicks": 0,
		}],
		"scheduling": {
			"nextJobId": 2, "jobSequence": 1, "jobTick": 0, "queueEventSequence": -1, "eventSequence": 0,
			"waiting": [queue_entry.duplicate(true)],
			"nextOrdinal": 1, "cursors": {},
			"pending": {
				"colonist_2": {
					"candidates": [queue_entry.duplicate(true)], "cursor": 0, "found": [],
					"start": _tile(0, 0), "route": route_state.duplicate(true),
				},
			},
			"assignments": {"colonist_1": {"jobId": "job_1", "startedTick": 0, "travelTicks": 0, "path": [_tile(0, 0), _tile(1, 1)]}},
			"activatedEntries": {"job_1": queue_entry.duplicate(true)},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [{"target": _tile(2, 2), "kind": "wall", "factionId": "colony"}],
		"zones": [], "nextZoneId": 1,
		"groundBerries": [{"target": _tile(3, 3), "berries": 1}],
		"workProgress": [{"target": _tile(4, 4), "ticksRemaining": 1}],
		"pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1, "state": 0}},
	}

func _flat_soil_tiles() -> Array:
	var tiles: Array = []
	tiles.resize(MAP_WIDTH * MAP_HEIGHT)
	tiles.fill("soil")
	return tiles
