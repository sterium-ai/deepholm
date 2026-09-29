class_name SaveMigrations
extends RefCounted

const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")

## Explicit migrations for persisted state dictionaries. A migration returns a
## new dictionary so reading an old save can never mutate the caller's state.
## Chains single-version steps so a save from any older version reaches
## to_version through every intermediate schema (e.g. v1 -> v2 -> v3), which
## is what lets SaveIO's read() keep calling migrate(state, version, SCHEMA_VERSION)
## unchanged as new schema versions are added.
static func migrate(state: Dictionary, from_version: int, to_version: int) -> Dictionary:
	var current_state := state
	var current_version := from_version
	while current_version < to_version:
		var step := _migrate_step(current_state, current_version)
		if not step["ok"]:
			return step
		current_state = step["state"]
		current_version += 1
	return {"ok": true, "code": "ok", "message": "save migrated", "state": current_state}

static func _migrate_step(state: Dictionary, from_version: int) -> Dictionary:
	var no_migration := {
		"ok": false,
		"code": "no_migration_available",
		"message": "no migration is available for this save schema",
	}
	match from_version:
		1:
			if not _is_schema_v1_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v1_to_v2(state)}
		2:
			if not _is_schema_v2_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v2_to_v3(state)}
		3:
			if not _is_schema_v3_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v3_to_v4(state)}
		4:
			if not _is_schema_v4_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v4_to_v5(state)}
		5:
			if not _is_schema_v5_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v5_to_v6(state)}
		6:
			if not _is_schema_v6_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v6_to_v7(state)}
		7:
			if not _is_schema_v7_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v7_to_v8(state)}
		8:
			if not _is_schema_v8_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v8_to_v9(state)}
		9:
			if not _is_schema_v9_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v9_to_v10(state)}
		10:
			if not _is_schema_v10_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v10_to_v11(state)}
		11:
			if not _is_schema_v11_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v11_to_v12(state)}
		12:
			if not _is_schema_v12_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v12_to_v13(state)}
		13:
			if not _is_schema_v13_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v13_to_v14(state)}
		14:
			if not _is_schema_v14_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v14_to_v15(state)}
		15:
			if not _is_schema_v15_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v15_to_v16(state)}
		16:
			if not _is_schema_v16_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v16_to_v17(state)}
		17:
			if not _is_schema_v17_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v17_to_v18(state)}
		18:
			if not _is_schema_v18_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v18_to_v19(state)}
		19:
			if not _is_schema_v19_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v19_to_v20(state)}
		20:
			if not _is_schema_v20_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v20_to_v21(state)}
		21:
			if not _is_schema_v21_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v21_to_v22(state)}
		22:
			if not _is_schema_v22_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v22_to_v23(state)}
		23:
			if not _is_schema_v23_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v23_to_v24(state)}
		24:
			if not _is_schema_v24_state(state):
				return no_migration
			return {"ok": true, "state": _migrate_v24_to_v25(state)}
		_:
			return no_migration

static func _is_schema_v1_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 1:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	return _has_dictionary_entries(state["entities"])

## _migrate_v2_to_v3() dereferences every entity as a Dictionary and every
## scheduling.assignments entry as a Dictionary; a malformed-but-integrity-valid
## save with the right top-level keys but the wrong nested shape must be
## rejected here, before migration touches it, rather than crash inside
## GDScript's `as Dictionary` casts.
static func _is_schema_v2_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 2:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v3_to_v4() only adds a fresh top-level key, but the shape checks
## for entities/scheduling are still needed so a malformed-but-v3-shaped save
## is rejected here rather than accepted and passed through unexamined.
static func _is_schema_v3_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "groundItems"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 3:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v4_to_v5() only adds a fresh per-route key, but the shape checks
## for entities/scheduling are still needed so a malformed-but-v4-shaped save
## is rejected here rather than accepted and passed through unexamined.
static func _is_schema_v4_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "groundItems", "objects"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 4:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v5_to_v6() dereferences every groundItems entry's "target" and
## "wood" fields and every entity as a Dictionary; the shape checks for
## entities/scheduling/groundItems are still needed so a malformed-but-v5-shaped
## save is rejected here rather than accepted and crashing migration's casts.
static func _is_schema_v5_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "groundItems", "objects"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 5:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["groundItems"]) != TYPE_ARRAY:
		return false
	for ground_item in state["groundItems"]:
		if typeof(ground_item) != TYPE_DICTIONARY:
			return false
		if typeof(ground_item.get("target")) != TYPE_DICTIONARY or typeof(ground_item.get("wood")) != TYPE_INT:
			return false
		var target: Dictionary = ground_item["target"]
		if not target.has("x") or not target.has("y"):
			return false
		if typeof(target["x"]) != TYPE_INT or typeof(target["y"]) != TYPE_INT:
			return false
		if int(target["x"]) < 0 or int(target["y"]) < 0:
			return false
		if int(ground_item["wood"]) < 0:
			return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v6_to_v7() only adds a fresh top-level key, but the shape checks
## for entities/scheduling/items are still needed so a malformed-but-v6-shaped
## save is rejected here rather than accepted and passed through unexamined.
static func _is_schema_v6_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 6:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v7_to_v8() dereferences every jobs entry as a Dictionary while
## backfilling the four new haul fields; the shape checks for entities/
## scheduling/items/jobs are still needed so a malformed-but-v7-shaped save
## is rejected here rather than accepted and crashing migration's casts.
static func _is_schema_v7_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 7:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v8_to_v9() only dereferences each entity as a Dictionary while
## backfilling "needs"; the shape checks for entities/items/jobs/scheduling
## are still needed so a malformed-but-v8-shaped save is rejected here rather
## than accepted and crashing migration's casts.
static func _is_schema_v8_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 8:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v9_to_v10() only adds a fresh top-level key, but the shape checks
## for entities/scheduling/items/jobs are still needed so a malformed-but-v9-shaped
## save is rejected here rather than accepted and passed through unexamined.
static func _is_schema_v9_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 9:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v10_to_v11() only adds fresh top-level keys, but the shape
## checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v10-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v10_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 10:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v11_to_v12() only dereferences each entity as a Dictionary while
## backfilling "labourTable"; the shape checks for entities/scheduling/items/
## jobs are still needed so a malformed-but-v11-shaped save is rejected here
## rather than accepted and crashing migration's casts.
static func _is_schema_v11_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 11:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v12_to_v13() only adds fresh top-level keys, but the shape checks
## for entities/scheduling/items/jobs are still needed so a
## malformed-but-v12-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v12_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 12:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v13_to_v14() only adds fresh top-level/nested keys, but the shape
## checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v13-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v13_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 13:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v14_to_v15() only adds fresh top-level keys, but the shape checks
## for entities/scheduling/items/jobs are still needed so a
## malformed-but-v14-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v14_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 14:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v15_to_v16() only adds a fresh top-level key, but the shape
## checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v15-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v15_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 15:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v16_to_v17() only adds a fresh top-level key, but the shape
## checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v16-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v16_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 16:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v17_to_v18() only dereferences each entity as a Dictionary while
## backfilling "factionId"/"health"; the shape checks for entities/scheduling/
## items/jobs are still needed so a malformed-but-v17-shaped save is rejected
## here rather than accepted and crashing migration's casts.
static func _is_schema_v17_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 17:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v18_to_v19() dereferences every items.list entry and every
## objects entry as a Dictionary while backfilling "factionId"; the shape
## checks for entities/scheduling/items/jobs are still needed (as well as the
## items.list/objects element checks below, mirroring _is_schema_v5_state's
## own groundItems element check) so a malformed-but-v18-shaped save is
## rejected here rather than accepted and crashing migration's casts.
static func _is_schema_v18_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 18:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	for item in (state["items"]["list"] as Array):
		if typeof(item) != TYPE_DICTIONARY:
			return false
	if typeof(state["objects"]) != TYPE_ARRAY:
		return false
	for object_entry in state["objects"]:
		if typeof(object_entry) != TYPE_DICTIONARY:
			return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v19_to_v20() dereferences state["map"] as a Dictionary while
## backfilling "generatorVersion"; otherwise identical to _is_schema_v18_state
## (same top-level shape, only the schemaVersion literal differs -- v18->v19
## added no top-level field, only "factionId" inside items.list/objects
## entries, which this shape checker never inspected either).
static func _is_schema_v19_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 19:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if typeof(state["map"]) != TYPE_DICTIONARY:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if typeof(state["objects"]) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v20_to_v21() only adds a fresh top-level key, but the shape
## checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v20-shaped save is rejected here rather than accepted and
## passed through unexamined.
static func _is_schema_v20_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 20:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if typeof(state["tick"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v21_to_v22() only dereferences each entity as a Dictionary while
## backfilling "needsAccumulator"; the shape checks for entities/scheduling/
## items/jobs are still needed so a malformed-but-v21-shaped save is rejected
## here rather than accepted and crashing migration's casts.
static func _is_schema_v21_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded", "incidentScheduler"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 21:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if not _has_valid_v21_entities_needs_shape(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v21_to_v22() dereferences a present entity["needs"] as a
## Dictionary to read its keys. A v21-shaped save whose "needs" is null, an
## array, or a scalar must be rejected here -- before migration touches it --
## rather than crash inside that cast.
static func _has_valid_v21_entities_needs_shape(entities: Array) -> bool:
	for entity in entities:
		var entity_dict: Dictionary = entity as Dictionary
		if entity_dict.has("needs") and typeof(entity_dict["needs"]) != TYPE_DICTIONARY:
			return false
	return true

static func _has_dictionary_entries(value) -> bool:
	if typeof(value) != TYPE_ARRAY:
		return false
	for entry in value:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
	return true

static func _has_valid_v2_scheduling_shape(value) -> bool:
	if typeof(value) != TYPE_DICTIONARY:
		return false
	var scheduling: Dictionary = value
	if not scheduling.has("assignments") or typeof(scheduling["assignments"]) != TYPE_DICTIONARY:
		return false
	var assignments: Dictionary = scheduling["assignments"]
	for worker in assignments.keys():
		if typeof(assignments[worker]) != TYPE_DICTIONARY:
			return false
	return true

static func _migrate_v1_to_v2(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 2
	# Version 1 predates scheduler snapshots: these are the truthful initial
	# continuation values, not defaults inferred from the current save.
	migrated["scheduling"] = {
		"nextJobId": 1,
		"jobSequence": 0,
		"jobTick": 0,
		"queueEventSequence": -1,
		"eventSequence": 0,
		"waiting": [],
		"nextOrdinal": 0,
		"cursors": {},
		"pending": {},
		"assignments": {},
	}
	var random := RandomNumberGenerator.new()
	random.seed = int(state["seed"])
	migrated["rng"] = {"seed": random.seed, "state": random.state}
	return migrated

static func _migrate_v2_to_v3(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 3
	# Version 2 predates trees and ground wood: no map tile could ever have
	# been a tree, so there is truthfully nothing to backfill here.
	migrated["groundItems"] = []
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		if not updated.has("route"):
			updated["route"] = null
		if not updated.has("work"):
			updated["work"] = null
		entities.append(updated)
	migrated["entities"] = entities
	# Version 2 assignments predate the resolved path field; an in-flight
	# assignment truthfully has no recorded route to backfill.
	var scheduling: Dictionary = (migrated["scheduling"] as Dictionary).duplicate(true)
	var assignments: Dictionary = (scheduling["assignments"] as Dictionary).duplicate(true)
	for worker in assignments.keys():
		var assignment: Dictionary = (assignments[worker] as Dictionary).duplicate(true)
		if not assignment.has("path"):
			assignment["path"] = []
		assignments[worker] = assignment
	scheduling["assignments"] = assignments
	migrated["scheduling"] = scheduling
	return migrated

static func _migrate_v3_to_v4(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 4
	# Version 3 predates placeable objects: no tile could ever have carried
	# one, so there is truthfully nothing to backfill besides an empty list.
	migrated["objects"] = []
	return migrated

## Version 4 predates re-routing: no existing route was ever mid-search, so
## there is truthfully nothing to backfill. A route's schemaVersion-5
## "rerouting" field is optional and omitted entirely for the normal
## (non-rerouting) state (see StateCodec._encode_route_field()), which is
## exactly the state every schemaVersion-4 route was already in -- so a v4
## route already satisfies the v5 shape unchanged, and only the version
## counter needs to move.
static func _migrate_v4_to_v5(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 5
	return migrated

## Version 5's groundItems was a per-tile wood counter ({target, wood}); this
## becomes one first-class item per unit of wood (colonist-ai.md 3.3/3.4), each
## a truthful count-1 "wood" item at that tile. Ids are assigned sequentially
## ("item_1", "item_2", ...) in groundItems' own (already tile-sorted, see
## StateCodec._encode_ground_items()) order, so the scheme is both stable
## (same input always yields the same ids) and non-colliding (every id is
## used exactly once); itemsNextId continues from the last id handed out here
## so a WorldState that keeps ticking after load never reuses one. Version 5
## also predates the colonist "carrying" field: no item could ever have been
## picked up, so every entity truthfully carries nothing.
static func _migrate_v5_to_v6(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 6
	var ground_items: Array = migrated["groundItems"]
	migrated.erase("groundItems")
	var list: Array = []
	var next_id := 1
	for ground_item in ground_items:
		var target: Dictionary = ground_item["target"]
		var wood := int(ground_item["wood"])
		for _unit in range(wood):
			list.append({
				"id": "item_%d" % next_id,
				"x": int(target["x"]), "y": int(target["y"]),
				"kind": "wood", "count": 1,
			})
			next_id += 1
	migrated["items"] = {"nextId": next_id, "list": list}
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		if not updated.has("carrying"):
			updated["carrying"] = null
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 6 predates stockpile zones: no zone could ever have been drawn, so
## there is truthfully nothing to backfill besides an empty list, and the
## fresh id counter that hands out the first zone's id starts at 1.
static func _migrate_v6_to_v7(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 7
	migrated["zones"] = []
	migrated["nextZoneId"] = 1
	return migrated

## Version 7 predates the haul job kind (#189): no job could ever have been a
## haul job, so every existing job truthfully carries an unclaimed item, no
## reserved cell, and no backoff -- itemId "", cell null, retryAt 0,
## backoffTicks 0, exactly JobQueue.submit_dig()'s own harmless defaults.
static func _migrate_v7_to_v8(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 8
	var jobs: Array = []
	for job in migrated["jobs"]:
		var updated: Dictionary = (job as Dictionary).duplicate(true)
		updated["itemId"] = ""
		updated["cell"] = null
		updated["retryAt"] = 0
		updated["backoffTicks"] = 0
		jobs.append(updated)
	migrated["jobs"] = jobs
	return migrated

## Version 8 predates colonist needs (#201): no colonist could ever have had
## food, water, or rest tracked, so every entity truthfully starts with a
## full (100) value of each kind (colonist-ai.md 3.1/3.8) -- the same value a
## freshly spawned colonist gets today (WorldState._full_needs()/NEED_FULL).
static func _migrate_v8_to_v9(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 9
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		updated["needs"] = {"food": 100, "water": 100, "rest": 100}
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 9 predates berry bushes and forage (#202): no forage job could ever
## have completed, so there is truthfully nothing to backfill besides an
## empty groundBerries list, mirroring the pre-#192 groundItems wire shape
## ({target, wood}) rather than the unified first-class items store --
## ground berries stay a simple per-tile counter (colonist-ai.md 3 result
## bullet 2), not a pickable item, so they get their own top-level array
## instead of joining "items".
static func _migrate_v9_to_v10(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 10
	migrated["groundBerries"] = []
	return migrated

## Version 10 predates tile work_progress and paused jobs (#205): no `work`
## toil could ever have been interrupted mid-tick-count, so there is
## truthfully nothing to backfill besides two honestly empty collections.
static func _migrate_v10_to_v11(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 11
	migrated["workProgress"] = []
	migrated["pausedJobs"] = []
	return migrated

## Version 11 predates the labour table (#207): no colonist could ever have
## had a labour kind toggled, so every entity truthfully starts at the same
## default all-3 table (colonist-ai.md 3.2) a freshly spawned colonist gets
## today (WorldState._default_labour_table()).
static func _migrate_v11_to_v12(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 12
	var default_labour_table := {
		"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3,
	}
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		updated["labourTable"] = default_labour_table.duplicate()
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 12 predates tool items (#213): no axe/pick could ever have
## existed, so there is truthfully nothing to backfill besides two honestly
## empty collections (colonist-ai.md 2/3.4). No entity could ever have held a
## tool either, so a v12 entity's absent heldTool is left absent rather than
## backfilled to "" -- StateCodec's own decoder already treats a missing
## heldTool as "" (see _decode_entities()).
static func _migrate_v12_to_v13(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 13
	migrated["toolItems"] = {"nextId": 1, "list": []}
	migrated["toolReservations"] = {}
	return migrated

## Version 13 predates two review-round-2 additions for #241's critical-need
## interrupt (colonist-ai.md 3.6): NeedGiver's own colonist_id -> job_id
## association (persisted so resolve_job() survives a save/load round trip)
## and each scheduler queue entry's "restrictTo" worker constraint (so a
## submitted need job can only ever be offered to the colonist whose need
## created it). A v13 save's need job, if any was queued or active at save
## time, truthfully never had that association recorded -- NeedGiver's own
## _pending was not persisted at all before this -- so there is nothing to
## backfill besides an honestly empty needJobAssignments list; every existing
## queue entry (waiting, each pending batch's candidates/found, and the
## fresh activatedEntries map itself) truthfully never restricted to a
## worker either, so "restrictTo" backfills to "" throughout and
## activatedEntries backfills to an honestly empty map (no v13 save ever
## tracked a job's original waiting-queue entry past its activation).
static func _migrate_v13_to_v14(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 14
	migrated["needJobAssignments"] = []
	var scheduling: Dictionary = (migrated["scheduling"] as Dictionary).duplicate(true)
	scheduling["waiting"] = _backfill_restrict_to(scheduling["waiting"])
	var pending: Dictionary = (scheduling["pending"] as Dictionary).duplicate(true)
	for worker in pending.keys():
		var request: Dictionary = (pending[worker] as Dictionary).duplicate(true)
		request["candidates"] = _backfill_restrict_to(request["candidates"])
		var found: Array = []
		for pair in (request["found"] as Array):
			var updated_pair: Dictionary = (pair as Dictionary).duplicate(true)
			updated_pair["entry"] = _backfilled_entry(updated_pair["entry"])
			found.append(updated_pair)
		request["found"] = found
		pending[worker] = request
	scheduling["pending"] = pending
	scheduling["activatedEntries"] = {}
	migrated["scheduling"] = scheduling
	return migrated

## Version 14 saves are migrated explicitly to version 15 (task #257,
## docs/architecture/foundation-for-breadth.md F1): a v14 save's shape is
## otherwise unchanged -- schemaVersion 15 only starts sourcing
## `contentVersion` from ContentRegistry.version() instead of a hard-coded
## literal (StateCodec.content_version()) and adds SaveIO's own contentVersion
## mismatch check on read, neither of which touches a save's persisted shape
## -- so there is truthfully nothing to backfill besides the version counter.
static func _migrate_v14_to_v15(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 15
	return migrated

## Version 15 predates the sowing-window calendar alert (issue #269, ADR 008
## consequence 6): no window could ever have fired yet, so there is
## truthfully nothing to backfill besides an honestly empty fired-window set.
static func _migrate_v15_to_v16(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 16
	migrated["calendarAlerts"] = {"fired": []}
	return migrated

## Version 16 predates the fetch_tool toil's own persisted excluded-candidate
## set (issue #271 round 6, ADR 012): no fetch attempt could ever have
## excluded a candidate under a pre-#271 or round-1-through-5 save, so there
## is truthfully nothing to backfill besides an honestly empty list.
static func _migrate_v16_to_v17(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 17
	migrated["toolFetchExcluded"] = []
	return migrated

## Version 17 predates per-actor faction membership and this schema's own
## persisted health (issue #284; the "health" runtime field itself was added
## to a colonist's live shape by issue #283's actor-component work, ADR 012,
## but the wire format never carried it -- WorldState._ensure_health()
## rebuilt a fresh one after every load instead). No entity could ever have
## belonged to a faction other than the colony, and no entity's hp/maxHp/dead
## was ever actually restored across a save/load round trip, so every
## existing entity is honestly backfilled with factionId: "colony" and a
## full-health snapshot ({hp: 100, maxHp: 100, dead: false}, matching
## ActorHealth.build_full()'s own colonist default) -- there is truthfully
## nothing else to recover.
static func _migrate_v17_to_v18(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 18
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		updated["factionId"] = "colony"
		updated["health"] = {"hp": 100, "maxHp": 100, "dead": false}
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 18 predates per-object/per-item faction ownership (issue #288): the
## persisted counterpart of the "faction_id" runtime field issue #287 added to
## WorldState.get_objects()/get_items() -- StateCodec's own encode() never
## wrote it to the wire before this version, mirroring how _migrate_v17_to_v18
## backfilled the same default for entities a version earlier. No object or
## item could ever have belonged to a faction other than the colony (the
## runtime field itself already defaults every not-yet-tracked object/item to
## "colony", see WorldState.get_objects()/get_items()), so every existing
## entry is honestly backfilled with factionId: "colony" -- there is
## truthfully nothing else to recover.
static func _migrate_v18_to_v19(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 19
	var items: Dictionary = (migrated["items"] as Dictionary).duplicate(true)
	var item_list: Array = []
	for item in (items["list"] as Array):
		var updated_item: Dictionary = (item as Dictionary).duplicate(true)
		updated_item["factionId"] = "colony"
		item_list.append(updated_item)
	items["list"] = item_list
	migrated["items"] = items
	var objects: Array = []
	for object_entry in migrated["objects"]:
		var updated_object: Dictionary = (object_entry as Dictionary).duplicate(true)
		updated_object["factionId"] = "colony"
		objects.append(updated_object)
	migrated["objects"] = objects
	return migrated

## Version 19 predates a persisted generator-algorithm identifier and a
## save's game-session epoch (issue #299, ADR 019): "map.width"/"map.height"
## already existed at v19 (the schema always declared them, encode() had
## simply always written the fixture's own 48/48 there), so no migration is
## needed for those. "map.generatorVersion" is new, backfilled to 1, the only
## worldgen algorithm that has ever produced a save
## (WorldGenerator.GENERATOR_VERSION did not exist before this task). "epoch"
## is new too, backfilled to 0 (SaveManager's own default for a save that
## never crossed a New Game boundary -- see save_manager.gd's header comment):
## every pre-v20 save was necessarily written before "New Game" existed.
static func _migrate_v19_to_v20(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 20
	var map: Dictionary = (migrated["map"] as Dictionary).duplicate(true)
	map["generatorVersion"] = 1
	migrated["map"] = map
	migrated["epoch"] = 0
	return migrated

## Version 20 saves are migrated explicitly to version 21 (F5, issue #294;
## docs/decisions/004-global-assignment-fairness-policy.md's "WorldState's
## diagnostic hash includes this continuation state"): a v20 save predates
## incidents, so no incident could ever have drawn or started a cooldown --
## `incidentScheduler.cooldownUntilDay` starts truthfully empty. `lastProcessedDay`
## is synced to the save's own current calendar day (`CalendarService.day_of_tick(tick)`),
## not 0, so a restored world does not treat every day it never actually lived
## through as newly due the moment incidents are enabled. `rng` is freshly
## re-seeded the exact same deterministic way `IncidentScheduler._init()`
## derives it from the save's own seed (`seed + IncidentScheduler.SEED_SALT`)
## -- there is truthfully nothing else to backfill.
static func _migrate_v20_to_v21(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 21
	var calendar := CalendarServiceType.new()
	var random := RandomNumberGenerator.new()
	random.seed = int(state["seed"]) + IncidentSchedulerType.SEED_SALT
	migrated["incidentScheduler"] = {
		"cooldownUntilDay": {},
		"lastProcessedDay": calendar.day_of_tick(int(state["tick"])),
		"rng": {"seed": random.seed, "state": random.state},
	}
	return migrated

## _migrate_v22_to_v23() only adds a fresh top-level key (digFindRng), but the
## shape checks for entities/scheduling/items/jobs are still needed so a
## malformed-but-v22-shaped save is rejected here rather than accepted and
## passed through unexamined. v22's allowed key set is identical to v21's:
## v21->v22 only added a per-entity field (needsAccumulator), never a
## top-level one.
static func _is_schema_v22_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded", "incidentScheduler"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in allowed:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 22:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## _migrate_v23_to_v24() only dereferences each entity as a Dictionary while
## backfilling "trapped"; the shape checks for entities/scheduling/items/jobs
## are still needed so a malformed-but-v23-shaped save is rejected here rather
## than accepted and crashing migration's casts. "digFindRng" is optional on
## the wire (ADR 025 round 2 amendment), so it is allowed but not required.
## "combatBlockedTargets" (round-4 review, #342/#302 merge) is likewise
## optional here: origin/main's own schemaVersion-23 encoder
## (StateCodec.encode(), CombatGiver's own flee-episode exclusions) has always
## written it unconditionally, even as an empty list, since the combat system
## landed on main -- but SaveIO._validate_state() itself already treats it as
## optional (see save_io.gd's own `optional_top_level`), so an ordinary
## pre-combat v23 save that never carries the key must keep migrating too.
static func _is_schema_v23_state(state: Dictionary) -> bool:
	var allowed := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded", "incidentScheduler", "digFindRng", "combatBlockedTargets"]
	var required := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded", "incidentScheduler"]
	for key in state.keys():
		if not allowed.has(key):
			return false
	for key in required:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 23:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	if state.has("digFindRng") and typeof(state["digFindRng"]) != TYPE_DICTIONARY:
		return false
	if state.has("combatBlockedTargets") and typeof(state["combatBlockedTargets"]) != TYPE_ARRAY:
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## Version 24 predates the hands model (issue #402, ADR 035): the top-level
## shape is otherwise identical to v23's own (the v23->v24 step above added
## no top-level key, only each entity's "trapped"), so "required"/"optional"
## below mirror SaveIO._validate_state()'s own top_level/optional_top_level
## lists -- the authoritative, always-current definition of what a real save
## from this build's encode() carries, several of whose entries
## (rescueVictimAssignments, workProgressOwners, suspendedWorkProgress,
## approachJobTargets, approachRetiredActors) postdate schemaVersion 23's own
## last real save and so are absent from _is_schema_v23_state()'s narrower,
## historically-accurate allowed list above.
static func _is_schema_v24_state(state: Dictionary) -> bool:
	var required := ["schemaVersion", "contentVersion", "seed", "tick", "epoch", "map", "entities", "inventory",
		"jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries",
		"workProgress", "pausedJobs", "toolItems", "toolReservations", "needJobAssignments", "calendarAlerts",
		"toolFetchExcluded", "incidentScheduler"]
	var optional := ["combatBlockedTargets", "digFindRng", "rescueVictimAssignments", "workProgressOwners",
		"suspendedWorkProgress", "approachJobTargets", "approachRetiredActors"]
	for key in state.keys():
		if not required.has(key) and not optional.has(key):
			return false
	for key in required:
		if not state.has(key):
			return false
	if typeof(state["schemaVersion"]) != TYPE_INT or int(state["schemaVersion"]) != 24:
		return false
	if typeof(state["seed"]) != TYPE_INT:
		return false
	if not _has_dictionary_entries(state["entities"]):
		return false
	if typeof(state["items"]) != TYPE_DICTIONARY or typeof(state["items"].get("list")) != TYPE_ARRAY:
		return false
	if not _has_dictionary_entries(state["jobs"]):
		return false
	if state.has("digFindRng") and typeof(state["digFindRng"]) != TYPE_DICTIONARY:
		return false
	if state.has("combatBlockedTargets") and typeof(state["combatBlockedTargets"]) != TYPE_ARRAY:
		return false
	return _has_valid_v2_scheduling_shape(state["scheduling"])

## Version 21 predates the per-need decay accumulator (issue #349, ADR 023):
## no entity could ever have carried one, and since a v21 save's needs were
## always decayed by a whole point per tick (no sub-point carry to lose), the
## honest backfill for every entity that already carries "needs" is a fresh
## zero accumulator for the same kinds -- not a guess, since v21 never tracked
## a fractional day any way.
static func _migrate_v21_to_v22(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 22
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		if updated.has("needs"):
			var accumulator: Dictionary = {}
			for kind in (updated["needs"] as Dictionary).keys():
				accumulator[kind] = 0
			updated["needsAccumulator"] = accumulator
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 22 predates the persisted dig-find RNG continuation (ADR 025
## amendment, issue #358 round 2 review): world._dig_find_random's own draw
## sequence was never written to the wire before this task, so no v22 save
## can carry a live run's true continuation to recover -- "digFindRng" is
## backfilled the exact same deterministic way WorldState._init() itself
## derives a fresh stream from the save's own seed (seed + WorldState.DIG_FIND_SEED_SALT),
## mirroring _migrate_v20_to_v21()'s identical incidentScheduler.rng backfill.
## A save that already completed one or more digs restarts its find sequence
## from this fresh point on its very next dig rather than silently resuming
## an unrecorded one -- the same one-time cost incidentScheduler.rng's own
## v20->v21 backfill already paid for incidents.
static func _migrate_v22_to_v23(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 23
	var random := RandomNumberGenerator.new()
	random.seed = int(state["seed"]) + WorldStateType.DIG_FIND_SEED_SALT
	migrated["digFindRng"] = {"seed": random.seed, "state": random.state}
	return migrated

## Version 23 predates a trapped actor's persisted state (issue #359, ADR 025
## t3): no actor could ever have stepped onto a trench tile and become trapped
## before this task's trap-on-entry mechanic landed, so every existing entity
## truthfully carries trapped: null -- mirroring _migrate_v5_to_v6()'s
## identical carrying: null backfill.
static func _migrate_v23_to_v24(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 24
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		updated["trapped"] = null
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

## Version 24 predates the hands model (issue #402, ADR 035): a colonist's
## single-slot "carrying" field ({"itemId","kind","count"} or null) becomes
## "hands", a list of {"kind","count"} entries -- empty when carrying was
## null, one entry carrying's own kind/count when it was populated. The
## item id is dropped: a hands entry has no id of its own (see
## StateCodec._encode_hands_field()), only the ground item place() later
## mints for it carries an id again. Any entity without a "carrying" field
## (a non-colonist kind) is left untouched.
static func _migrate_v24_to_v25(state: Dictionary) -> Dictionary:
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 25
	var entities: Array = []
	for entity in migrated["entities"]:
		var updated: Dictionary = (entity as Dictionary).duplicate(true)
		if updated.has("carrying"):
			var carrying = updated["carrying"]
			updated["hands"] = [] if carrying == null else [{"kind": carrying["kind"], "count": carrying["count"]}]
			updated.erase("carrying")
		entities.append(updated)
	migrated["entities"] = entities
	return migrated

static func _backfill_restrict_to(entries: Array) -> Array:
	var updated: Array = []
	for entry in entries:
		updated.append(_backfilled_entry(entry))
	return updated

static func _backfilled_entry(entry: Dictionary) -> Dictionary:
	var updated: Dictionary = entry.duplicate(true)
	updated["restrictTo"] = ""
	return updated

# --- content-rename hook (task #257) ----------------------------------------

## Resolves a schemaVersion mismatch between a save's own `contentVersion` and
## the content bundle currently on disk (docs/architecture/foundation-for-
## breadth.md F1: "a content version goes into every save ... with a
## migration hook for content renames"). Keyed by the exact stored
## contentVersion a save was written under. A registered remap is a
## Callable(state: Dictionary) -> Dictionary that returns a new state with
## every renamed content id remapped, never mutating its argument, matching
## every _migrate_vN_to_vN+1 step above.
static var _content_renames: Dictionary = {}

## Godot's static-variable initializer callback (run once, at class load,
## before any static method executes): registers this task's own real
## production entry (issue #449) alongside whatever a test additionally
## registers/unregisters for its own scenario.
static func _static_init() -> void:
	register_content_rename(WALL_RENAME_FROM_CONTENT_VERSION, Callable(SaveMigrations, "_rename_wall_to_wooden_wall"))

## manifest.json's own "version" field before this task renamed
## content/objects.json's "wall" row to "wooden_wall"/"stone_wall" -- read
## live off the pre-change checkout (game/content/manifest.json), never
## hand-typed or guessed. Every save written under this exact contentVersion
## can still carry a persisted object of kind "wall".
const WALL_RENAME_FROM_CONTENT_VERSION := "1.0.0"

## Issue #449's own real content rename: every persisted object whose kind is
## the retired "wall" id becomes "wooden_wall", content/objects.json's own
## replacement for it (build_cost wood, matching "wall"'s own former
## build_cost exactly; "stone_wall" is a new addition, not a rename target,
## so no save ever names it under the old contentVersion). resolve_content_version()
## sets the returned state's own contentVersion, so this remap only ever
## touches content-id fields already present on the state: a completed
## object's own "kind", an in-progress construction site's own "kind"
## (round 2 review: a pre-task save can carry an unfinished "wall" site just
## as easily as a completed "wall" object, and ADR 038's own persisted
## requiredMaterials/heldMaterials/progress/buildTicks/builderIds on that site
## record are left untouched here -- only "kind" is a content id, the rest is
## the site's own truthful history), and a still-legacy (pre-#406) build
## job's own retired "buildKind" field (round 2 review: SaveIO now resolves
## this rename before SaveMigrations.migrate_legacy_build_jobs() looks
## buildKind up against the current content bundle, so a queued/active
## legacy "wall" build job must have its own buildKind renamed here too, or
## that lookup would still miss and synthesize an empty-cost site).
## Round 2 review: a save missing "objects"/"jobs" (or carrying either as the
## wrong type, or an entry inside one of the three renamed collections that is
## not itself a Dictionary) must reach _validate_state() exactly as malformed
## as it arrived -- never fabricated into an empty (and therefore
## structurally valid-looking) collection, and never blindly cast in a way
## that raises a script error before validation ever runs. Each collection
## below is therefore only ever touched when it is already present AND typed
## as an Array; a present-but-wrong-typed field, or a non-Dictionary entry
## inside it, is passed through completely untouched so the real error
## surfaces from _validate_state()'s own type/shape checks, not from a script
## error or an invented default here. Round 4 review: the same rule applies one
## level deeper -- each entry's own "kind"/"buildKind" field is only compared
## against "wall" (via `is String`, matching every other type check in this
## file and save_io.gd) when it is already a String; a numeric, Array,
## Dictionary, or null value there is left untouched rather than passed
## through the former unconditional String() cast, which raises a script error
## for those types.
static func _rename_wall_to_wooden_wall(state: Dictionary) -> Dictionary:
	var migrated: Dictionary = state.duplicate(true)
	if migrated.get("objects") is Array:
		var objects: Array = []
		for object_value in (migrated["objects"] as Array):
			if object_value is Dictionary:
				var object_entry: Dictionary = (object_value as Dictionary).duplicate(true)
				if object_entry.get("kind") is String and object_entry["kind"] == "wall":
					object_entry["kind"] = "wooden_wall"
				objects.append(object_entry)
			else:
				objects.append(object_value)
		migrated["objects"] = objects
	if migrated.get("constructionSites") is Array:
		var sites: Array = []
		for site_value in (migrated["constructionSites"] as Array):
			if site_value is Dictionary:
				var site_entry: Dictionary = (site_value as Dictionary).duplicate(true)
				if site_entry.get("kind") is String and site_entry["kind"] == "wall":
					site_entry["kind"] = "wooden_wall"
				sites.append(site_entry)
			else:
				sites.append(site_value)
		migrated["constructionSites"] = sites
	if migrated.get("jobs") is Array:
		var jobs: Array = []
		for job_value in (migrated["jobs"] as Array):
			if job_value is Dictionary:
				var job_entry: Dictionary = (job_value as Dictionary).duplicate(true)
				if job_entry.get("buildKind") is String and job_entry["buildKind"] == "wall":
					job_entry["buildKind"] = "wooden_wall"
				jobs.append(job_entry)
			else:
				jobs.append(job_value)
		migrated["jobs"] = jobs
	return migrated

## Registration seam used both by this file's own production entry above
## (_static_init()) and by test_save_migration.gd's rename-hook checks for
## their own additional, test-only scenarios.
static func register_content_rename(from_content_version: String, remap: Callable) -> void:
	_content_renames[from_content_version] = remap

## Removes exactly one registered entry, leaving every other registration
## (including this file's own production entry) untouched -- unlike a
## clear-everything reset, which would silently erase the production wall
## rename for the rest of the same test process.
static func unregister_content_rename(from_content_version: String) -> void:
	_content_renames.erase(from_content_version)

## {"ok": false} when no rename is registered for state's exact stored
## contentVersion -- the caller (SaveIO._read_and_verify()) turns that into
## the content_version_mismatch error. On success the returned state's
## contentVersion is already set to to_content_version, so the caller needs no
## further patching before re-validating.
static func resolve_content_version(state: Dictionary, to_content_version: String) -> Dictionary:
	var from_content_version := String(state.get("contentVersion", ""))
	if not _content_renames.has(from_content_version):
		return {"ok": false}
	var remap: Callable = _content_renames[from_content_version]
	var resolved: Dictionary = (remap.call(state) as Dictionary).duplicate(true)
	resolved["contentVersion"] = to_content_version
	return {"ok": true, "state": resolved}

# --- legacy build-job compatibility (issue #406) ----------------------------

## A save written before construction sites existed can still carry a "build"
## job (JobQueue.BUILD_KIND, the single-worker fetch-then-work job issue #406
## replaced with the persistent site model) even though schemaVersion never
## moved for this change -- "site_fetch"/"site_work" and constructionSites
## only widened the existing wire shape (see save_io.gd's own job kind enum
## and optional_top_level list), the same additive-compatibility rule every
## other same-version field addition in this file already follows. Applied
## unconditionally by SaveIO._read_and_verify() right after the schemaVersion
## migration chain (which never touches job "kind"), before validation, so
## _validate_state() only ever has to know about the current wire shape.
##
## A legacy build job's own progress lived entirely in the builder's hands
## (spent atomically at completion) and a job-id-keyed workProgress entry --
## neither maps onto a site's own held_materials/progress, which this task's
## model tracks on the site record itself. There is truthfully nothing to
## resume, so a still-queued or -active legacy build job is converted into a
## fresh, empty construction site at its own site tile (the honest "restart
## cleanly" backfill _migrate_v22_to_v23's RNG restart already established)
## and its own job becomes a "site_fetch" job pointed at it; ConstructionGiver
## re-derives real fetch/work jobs for it from scratch on the very next tick.
## A terminal (completed/failed/cancelled) legacy job carries no live
## execution state at all -- its own kind is still renamed for consistency
## (SaveIO's job kind enum no longer needs to carry "build" as a permanently
## accepted legacy value), but no site is fabricated for it.
static func migrate_legacy_build_jobs(state: Dictionary) -> Dictionary:
	var jobs = state.get("jobs")
	if typeof(jobs) != TYPE_ARRAY:
		return state
	var has_legacy_build := false
	for job in jobs:
		if typeof(job) == TYPE_DICTIONARY and String((job as Dictionary).get("kind", "")) == "build":
			has_legacy_build = true
			break
	if not has_legacy_build:
		return state

	var migrated := state.duplicate(true)
	var sites: Array = (migrated.get("constructionSites", []) as Array).duplicate(true)
	var known_origins := {}
	var next_id := 1
	for site in sites:
		var site_dict: Dictionary = site
		known_origins[_legacy_build_site_origin_key(site_dict["origin"])] = true
		var id := String(site_dict["id"])
		if id.begins_with("site_"):
			next_id = maxi(next_id, int(id.substr(5)) + 1)

	var registry := ContentRegistryType.new()
	var updated_jobs: Array = []
	for job_value in (migrated["jobs"] as Array):
		var job: Dictionary = (job_value as Dictionary).duplicate(true)
		if String(job.get("kind", "")) == "build":
			var site_tile = job.get("site")
			if site_tile is Dictionary and String(job.get("status", "")) in ["queued", "active"]:
				var origin_key := _legacy_build_site_origin_key(site_tile)
				if not known_origins.has(origin_key):
					var build_kind := String(job.get("buildKind", ""))
					var definition := registry.get_entry("objects", build_kind)
					sites.append({
						"id": "site_%d" % next_id,
						"kind": build_kind,
						"origin": site_tile,
						"orientation": "",
						"requiredMaterials": (definition.get("build_cost", []) as Array).duplicate(true),
						"heldMaterials": [],
						"progress": 0,
						"buildTicks": int(definition.get("build_ticks", 1)),
						"maxBuilders": int(definition.get("max_builders", 1)),
						"builderIds": [],
					})
					next_id += 1
					known_origins[origin_key] = true
			job["kind"] = "site_fetch"
			job.erase("buildKind")
		updated_jobs.append(job)
	migrated["jobs"] = updated_jobs
	migrated["constructionSites"] = sites
	return migrated

static func _legacy_build_site_origin_key(tile: Dictionary) -> String:
	return "%d_%d" % [int(tile["x"]), int(tile["y"])]
