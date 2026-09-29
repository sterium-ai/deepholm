extends SceneTree

## Exercises SaveMigrations.migrate() directly to prove the chained
## v1->v2->v3 and v2->v3 migrations shape their output correctly, independent
## of SaveIO's own schema validator, then separately proves both fixtures are
## real loadable save envelopes by reading them through SaveIO.read(), which
## additionally checks their integrity hash and runs the current schema's
## _validate_state. Also proves malformed-but-shape-matching v1/v2 saves are
## rejected explicitly rather than crashing inside migration's internal casts.
const SaveIOType = preload("res://scripts/core/persistence/save_io.gd")
const SaveMigrationsType = preload("res://scripts/core/persistence/save_migrations.gd")
const StateCodecType = preload("res://scripts/core/persistence/state_codec.gd")
const WorldStateType = preload("res://scripts/core/world_state.gd")
const CalendarServiceType = preload("res://scripts/core/calendar/calendar_service.gd")
const IncidentSchedulerType = preload("res://scripts/core/incidents/incident_scheduler.gd")
const ContentRegistryType = preload("res://scripts/core/content/content_registry.gd")
const FIXTURE_V1 := "res://scripts/tests/fixtures/save_schema_v1_fixture.json"
const FIXTURE_V2 := "res://scripts/tests/fixtures/save_schema_v2_fixture.json"
const FIXTURE_V3 := "res://scripts/tests/fixtures/save_schema_v3_fixture.json"
const FIXTURE_V4 := "res://scripts/tests/fixtures/save_schema_v4_fixture.json"
const FIXTURE_V5 := "res://scripts/tests/fixtures/save_schema_v5_fixture.json"
const FIXTURE_V6 := "res://scripts/tests/fixtures/save_schema_v6_fixture.json"
const FIXTURE_V7 := "res://scripts/tests/fixtures/save_schema_v7_fixture.json"
const FIXTURE_V8 := "res://scripts/tests/fixtures/save_schema_v8_fixture.json"
const FIXTURE_V9 := "res://scripts/tests/fixtures/save_schema_v9_fixture.json"
const FIXTURE_V10 := "res://scripts/tests/fixtures/save_schema_v10_fixture.json"
const FIXTURE_V11 := "res://scripts/tests/fixtures/save_schema_v11_fixture.json"

## #269: a real schemaVersion-15 save file (this task's own predecessor
## schema, current on main before ADR 008's calendar alert wiring), the
## fixtures/ directory being an owned path for this task unlike #243/#257's
## inline v13/v14 literals above.
const FIXTURE_V16 := "res://scripts/tests/fixtures/save_schema_v16_fixture.json"

## #288: a real schemaVersion-18 save file (this task's own predecessor
## schema, current on main before per-object/per-item faction ownership was
## persisted), named for its own schemaVersion like the v1..v11 fixture files
## above rather than FIXTURE_V16's target-version naming.
const FIXTURE_V18 := "res://scripts/tests/fixtures/save_schema_v18_fixture.json"

## #295: a real schemaVersion-20 save file (this task's own predecessor
## schema, current on main before the incident scheduler's continuation state
## was persisted), named for its own schemaVersion like FIXTURE_V18 above.
const FIXTURE_V20 := "res://scripts/tests/fixtures/save_schema_v20_fixture.json"

## #243 review round 1: the v13 fixture must live inside this owned test file
## rather than as a separate game/scripts/tests/fixtures/ file (that
## directory is not one of this task's owned paths). Written to a user://
## temp file at runtime (see _write_v13_fixture()) so _check_v13_fixture_loads_through_save_io()
## still exercises SaveIO.read()'s real file I/O and integrity-hash
## verification, not just a Dictionary literal.
const V13_FIXTURE_DIR := "user://test-save-migration-v13-fixture"
const V13_FIXTURE_STATE := {
	"schemaVersion": 13, "contentVersion": "1.0.0", "seed": 135791, "tick": 3,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"]},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 70, "water": 80, "rest": 90},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"needs": {"food": 40, "water": 50, "rest": 60},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 3, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {},
	},
	"rng": {"seed": 135791, "state": 24},
	"items": {"nextId": 3, "list": [{"id": "item_2", "x": 2, "y": 0, "kind": "wood", "count": 3}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [{"target": {"x": 2, "y": 1}, "ticksRemaining": 9}],
	"pausedJobs": [{"colonistId": "colonist_0", "jobId": "job-1"}],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
}

## #257: a real schema-14 save file, mirroring V13_FIXTURE_STATE one version
## up -- one colonist holding a tool, a queued job with its own waiting-queue
## entry mirrored into activatedEntries, a ground item/object/zone/berry
## patch -- but with the three #241-round-2 fields v13 predates
## (needJobAssignments, waiting/activatedEntries restrictTo) now genuinely
## populated rather than backfilled placeholders, so this fixture is not just
## V13_FIXTURE_STATE with the version counter bumped.
const V14_FIXTURE_DIR := "user://test-save-migration-v14-fixture"
const V14_FIXTURE_STATE := {
	"schemaVersion": 14, "contentVersion": "1.0.0", "seed": 246813, "tick": 5,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"]},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 65, "water": 75, "rest": 85},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
	],
	"inventory": {},
	"jobs": [
		{
			"id": "job_1", "kind": "dig", "status": "queued", "priority": 1, "target": {"x": 2, "y": 0},
			"reason": "", "remedy": "", "blockingJobId": "", "itemId": "", "cell": null,
			"retryAt": 0, "backoffTicks": 0,
		},
	],
	"scheduling": {
		"nextJobId": 2, "jobSequence": 1, "jobTick": 5, "queueEventSequence": -1, "eventSequence": 0,
		"waiting": [{"id": "job_1", "target": {"x": 2, "y": 0}, "base": 5, "submittedTick": 0, "ordinal": 0, "restrictTo": "colonist_0"}],
		"nextOrdinal": 1, "cursors": {}, "pending": {}, "assignments": {},
		"activatedEntries": {"job_1": {"id": "job_1", "target": {"x": 2, "y": 0}, "base": 5, "submittedTick": 0, "ordinal": 0, "restrictTo": "colonist_0"}},
	},
	"rng": {"seed": 246813, "state": 17},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [{"colonistId": "colonist_0", "jobId": "job_1"}],
}

## #284: a real schema-17 save file (this task's own predecessor schema),
## mirroring V13_FIXTURE_STATE/V14_FIXTURE_STATE's inline-literal precedent
## (the fixtures/ directory is not this task's own extension point for a new
## fixture file): one colonist holding a tool, one colonist carrying an item,
## a fired calendar alert, and a populated toolFetchExcluded entry, none of
## which any earlier fixture in this file exercises together with the two new
## v18 entity fields this task adds.
const V17_FIXTURE_DIR := "user://test-save-migration-v17-fixture"
const V17_FIXTURE_STATE := {
	"schemaVersion": 17, "contentVersion": "1.0.0", "seed": 357911, "tick": 8,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"]},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 55, "water": 65, "rest": 75},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"needs": {"food": 45, "water": 55, "rest": 65},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 8, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 357911, "state": 31},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": ["SpringSow"]},
	"toolFetchExcluded": [{"jobId": "job_1", "toolIds": ["tool_1"]}],
}

## #257: proves SaveIO.read() rejects a save whose contentVersion has no
## registered rename with the new typed content_version_mismatch code, never
## silently proceeding with a stale content id.
const CONTENT_MISMATCH_FIXTURE_DIR := "user://test-save-migration-content-mismatch-fixture"

## #257: proves the content-rename hook actually runs (not just the mismatch
## check itself) by registering a rename for this exact source contentVersion
## and asserting the loaded state's renamed content id took effect.
const CONTENT_RENAME_FIXTURE_DIR := "user://test-save-migration-content-rename-fixture"
const RENAME_SOURCE_CONTENT_VERSION := "test-legacy-content-version"

## Issue #449: fixture directory for the production wall->wooden_wall
## content-rename hook check, distinct from CONTENT_RENAME_FIXTURE_DIR above
## (that one exercises a test-registered rename, not the real one).
const WALL_RENAME_FIXTURE_DIR := "user://test-save-migration-wall-rename-fixture"

## Round 2 review (issue #449): fixture directory for a pre-task save that
## still carries an UNFINISHED "wall" construction site (ADR 038), proving the
## production content-rename hook renames a constructionSites[].kind entry
## (not just a completed objects[].kind entry) and that the renamed site can
## still be delivered to and completed after load.
const WALL_SITE_RENAME_FIXTURE_DIR := "user://test-save-migration-wall-site-rename-fixture"

## Round 2 review (issue #449): fixture directory for a pre-task save that
## still carries a queued/active legacy (pre-#406) "build" job whose own
## retired buildKind is "wall", proving SaveIO resolves the content-rename
## before SaveMigrations.migrate_legacy_build_jobs() looks buildKind up
## against the current content bundle -- otherwise that lookup misses and
## synthesizes an empty-cost, one-tick site instead of a real wooden_wall one.
const LEGACY_WALL_BUILD_JOB_FIXTURE_DIR := "user://test-save-migration-legacy-wall-build-job-fixture"

## Round 2 review (issue #449): fixture directories for a save entering the
## content-rename path (contentVersion == WALL_RENAME_FROM_CONTENT_VERSION)
## with a missing/malformed "objects", "constructionSites", "jobs", or
## "contentVersion" field. Before the round-2 fix, SaveMigrations'
## _rename_wall_to_wooden_wall() fabricated an empty objects/jobs array when
## either was absent (masking a missing-field rejection) and blindly cast
## every collection/entry, raising a script error for a malformed one instead
## of letting _validate_state() reject it structurally. Each of these must be
## rejected with the same typed error _validate_state() would give an
## ordinary (non-rename-path) save with the same defect -- never accepted,
## and never a script error.
const WALL_RENAME_MISSING_OBJECTS_FIXTURE_DIR := "user://test-save-migration-wall-rename-missing-objects-fixture"
const WALL_RENAME_MISSING_JOBS_FIXTURE_DIR := "user://test-save-migration-wall-rename-missing-jobs-fixture"
const WALL_RENAME_MISSING_CONTENT_VERSION_FIXTURE_DIR := "user://test-save-migration-wall-rename-missing-content-version-fixture"
const WALL_RENAME_INVALID_CONTENT_VERSION_TYPE_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-content-version-type-fixture"
const WALL_RENAME_INVALID_OBJECTS_CONTAINER_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-objects-container-fixture"
const WALL_RENAME_INVALID_OBJECTS_ENTRY_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-objects-entry-fixture"
const WALL_RENAME_INVALID_SITES_CONTAINER_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-sites-container-fixture"
const WALL_RENAME_INVALID_SITES_ENTRY_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-sites-entry-fixture"
const WALL_RENAME_INVALID_JOBS_CONTAINER_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-jobs-container-fixture"
const WALL_RENAME_INVALID_JOBS_ENTRY_FIXTURE_DIR := "user://test-save-migration-wall-rename-invalid-jobs-entry-fixture"
const WALL_RENAME_NON_STRING_OBJECT_KIND_FIXTURE_DIR := "user://test-save-migration-wall-rename-non-string-object-kind-fixture"
const WALL_RENAME_NON_STRING_SITE_KIND_FIXTURE_DIR := "user://test-save-migration-wall-rename-non-string-site-kind-fixture"
const WALL_RENAME_NON_STRING_JOB_BUILD_KIND_FIXTURE_DIR := "user://test-save-migration-wall-rename-non-string-job-build-kind-fixture"

## #299: a real schema-19 save file (this task's own predecessor schema,
## current on main before "map.generatorVersion" was persisted), mirroring
## V17_FIXTURE_STATE one version up -- items/objects already carry factionId
## (added at v19), entities already carry factionId/health (added at v18),
## but "map" has no "generatorVersion" field yet, the one thing v19->v20 adds.
const V19_FIXTURE_DIR := "user://test-save-migration-v19-fixture"
const V19_FIXTURE_STATE := {
	"schemaVersion": 19, "contentVersion": "1.0.0", "seed": 579113, "tick": 9,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"]},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 60, "water": 70, "rest": 80},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 50, "water": 60, "rest": 70},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 9, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 579113, "state": 51},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3, "factionId": "colony"}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall", "factionId": "colony"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": []},
	"toolFetchExcluded": [],
}

## #349: a real schemaVersion-21 save file (this task's own predecessor
## schema, current on main before the per-need decay accumulator was
## persisted), mirroring V19_FIXTURE_STATE one version up -- "map" already
## carries generatorVersion and the top level already carries "epoch" (added
## at v20) and "incidentScheduler" (added at v21), but no entity carries
## "needsAccumulator" yet, the one thing v21->v22 adds.
const V21_FIXTURE_DIR := "user://test-save-migration-v21-fixture"
const V21_FIXTURE_STATE := {
	"schemaVersion": 21, "contentVersion": "1.0.0", "seed": 246801, "tick": 11,
	"epoch": 0,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"], "generatorVersion": 1},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 65, "water": 75, "rest": 85},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 55, "water": 65, "rest": 75},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 11, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 246801, "state": 51},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3, "factionId": "colony"}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall", "factionId": "colony"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": []},
	"toolFetchExcluded": [],
	"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1160801, "state": 0}},
}

## Issue #358 round 2 review (ADR 025 amendment): a real schemaVersion-22 save
## file (this task's own predecessor schema, current on main before the
## dig-find RNG continuation was persisted), mirroring V21_FIXTURE_STATE one
## version up -- every entity already carries "needsAccumulator" (added at
## v22), but the top level carries no "digFindRng" yet, the one thing
## v22->v23 adds.
const V22_FIXTURE_DIR := "user://test-save-migration-v22-fixture"
const V22_FIXTURE_STATE := {
	"schemaVersion": 22, "contentVersion": "1.0.0", "seed": 357024, "tick": 13,
	"epoch": 0,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"], "generatorVersion": 1},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 60, "water": 70, "rest": 80},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 50, "water": 60, "rest": 70},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 13, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 357024, "state": 61},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3, "factionId": "colony"}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall", "factionId": "colony"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": []},
	"toolFetchExcluded": [],
	"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1471024, "state": 0}},
}

## Issue #359 (ADR 025 t3): a real schemaVersion-23 save file (this task's own
## predecessor schema, current on main before trapped-actor state was
## persisted), mirroring V22_FIXTURE_STATE one version up -- every entity
## already carries "needsAccumulator" (v22) and the top level already carries
## "digFindRng" (v23), but no entity carries "trapped" yet, the one thing
## v23->v24 adds.
const V23_FIXTURE_DIR := "user://test-save-migration-v23-fixture"
const V23_FIXTURE_STATE := {
	"schemaVersion": 23, "contentVersion": "1.0.0", "seed": 468135, "tick": 17,
	"epoch": 0,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"], "generatorVersion": 1},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 60, "water": 70, "rest": 80},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1",
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 50, "water": 60, "rest": 70},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 1}, "heldTool": "",
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 17, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 468135, "state": 61},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3, "factionId": "colony"}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall", "factionId": "colony"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": []},
	"toolFetchExcluded": [],
	"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1471024, "state": 0}},
	"digFindRng": {"seed": 468135, "state": 0},
	# Round-4 review: origin/main's own schemaVersion-23 encoder (the #342 combat
	# merge) writes this field unconditionally, so a REAL v23 save from current
	# main always carries a populated one, not just an empty list -- this
	# fixture must exercise that shape, or the migration shape-check regression
	# that rejected it goes uncaught (see _is_schema_v23_state()'s own comment).
	"combatBlockedTargets": [{"actorId": "colonist_1", "tiles": [{"x": 2, "y": 1}, {"x": 0, "y": 1}]}],
}

## Issue #402 (ADR 035): a real schemaVersion-24 save file (this task's own
## predecessor schema, current on main before the hands model), mirroring
## V23_FIXTURE_STATE one version up -- every entity already carries "trapped"
## (v23->v24) but still the single-slot "carrying" field (null or populated)
## v24 itself predates replacing with "hands". colonist_0's null carrying
## must migrate to an empty hands array; colonist_1's populated carrying
## (count 3, distinguishable from a bare single unit) must migrate to a
## one-entry hands array preserving kind/count.
const V24_FIXTURE_DIR := "user://test-save-migration-v24-fixture"
const V24_FIXTURE_STATE := {
	"schemaVersion": 24, "contentVersion": "1.0.0", "seed": 579246, "tick": 21,
	"epoch": 0,
	"map": {"width": 3, "height": 2, "tiles": ["soil", "floor", "soil", "rock", "hazard", "tree"], "generatorVersion": 1},
	"entities": [
		{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 60, "water": 70, "rest": 80},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null, "heldTool": "tool_1", "trapped": null,
		},
		{
			"id": "colonist_1", "kind": "colonist", "x": 1, "y": 0,
			"factionId": "colony", "health": {"hp": 100, "maxHp": 100, "dead": false},
			"needs": {"food": 50, "water": 60, "rest": 70},
			"needsAccumulator": {"food": 0, "water": 0, "rest": 0},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": {"itemId": "item_1", "kind": "wood", "count": 3}, "heldTool": "", "trapped": null,
		},
	],
	"inventory": {}, "jobs": [],
	"scheduling": {
		"nextJobId": 1, "jobSequence": 0, "jobTick": 21, "queueEventSequence": -1,
		"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
		"assignments": {}, "activatedEntries": {},
	},
	"rng": {"seed": 579246, "state": 61},
	"items": {"nextId": 2, "list": [{"id": "item_1", "x": 2, "y": 0, "kind": "wood", "count": 3, "factionId": "colony"}]},
	"objects": [{"target": {"x": 2, "y": 1}, "kind": "wall", "factionId": "colony"}],
	"zones": [{"id": "zone_1", "x": 2, "y": 0, "width": 1, "height": 1}], "nextZoneId": 2,
	"groundBerries": [{"target": {"x": 0, "y": 1}, "berries": 2}],
	"workProgress": [], "pausedJobs": [],
	"toolItems": {"nextId": 2, "list": [{"id": "tool_1", "kind": "axe", "location": {"type": "held", "colonistId": "colonist_0"}}]},
	"toolReservations": {},
	"needJobAssignments": [],
	"calendarAlerts": {"fired": []},
	"toolFetchExcluded": [],
	"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1471024, "state": 0}},
}

## Round 2 review regression: calendar window ids come from content/calendar.json,
## whose own schema (game/content/schemas/calendar.schema.json) allows any
## non-empty string, not the stricter ^[a-z0-9_-]+$ pattern _matches_id_pattern()
## enforces for entity/job/item ids. A valid window id like "SpringSow" must
## still round-trip through SaveIO.read(), not just an in-memory _validate_state call.
const CALENDAR_ID_FIXTURE_DIR := "user://test-save-migration-calendar-id-fixture"

## Round-4 review regression (#406): a save carrying a legacy "build" job
## (JobQueue.BUILD_KIND, the single-worker job the construction-site model
## replaced) at the CURRENT schemaVersion -- construction sites were added
## without a version bump, so this scenario is not covered by any vN fixture
## above. Used by _check_legacy_build_job_loads_through_save_io().
const LEGACY_BUILD_JOB_FIXTURE_DIR := "user://test-save-migration-legacy-build-job-fixture"

## Round 2 review regression (#295): _migrate_v20_to_v21() calls int(state["tick"])
## to derive incidentScheduler.lastProcessedDay; _is_schema_v20_state() must
## reject a Dictionary/Array "tick" before that conversion runs, not let it
## reach a script error. Used by _check_malformed_v20_tick_rejected_through_save_io()
## to prove the same rejection holds through a real integrity-valid envelope.
const V20_TICK_FIXTURE_DIR := "user://test-save-migration-v20-tick-fixture"

## Round 1 review regression (#349): _is_schema_v21_state() checked that
## entities were dictionaries but never that a present entity["needs"] was
## itself a Dictionary, so a v21 fixture with needs null, an array, or a
## scalar reached _migrate_v21_to_v22()'s unguarded `(needs as Dictionary).keys()`
## cast and threw a script error instead of a typed no_migration_available
## rejection. Used by _check_malformed_v21_needs_*_rejected_through_save_io().
const V21_NEEDS_NULL_FIXTURE_DIR := "user://test-save-migration-v21-needs-null-fixture"
const V21_NEEDS_ARRAY_FIXTURE_DIR := "user://test-save-migration-v21-needs-array-fixture"
const V21_NEEDS_SCALAR_FIXTURE_DIR := "user://test-save-migration-v21-needs-scalar-fixture"

var _failed := false
var _v13_fixture_path := ""
var _v14_fixture_path := ""
var _v17_fixture_path := ""
var _v19_fixture_path := ""
var _v21_fixture_path := ""
var _v22_fixture_path := ""
var _v23_fixture_path := ""
var _v24_fixture_path := ""

func _init() -> void:
	_v13_fixture_path = _write_state_fixture(V13_FIXTURE_DIR, V13_FIXTURE_STATE)
	_v14_fixture_path = _write_state_fixture(V14_FIXTURE_DIR, V14_FIXTURE_STATE)
	_v17_fixture_path = _write_state_fixture(V17_FIXTURE_DIR, V17_FIXTURE_STATE)
	_v19_fixture_path = _write_state_fixture(V19_FIXTURE_DIR, V19_FIXTURE_STATE)
	_v21_fixture_path = _write_state_fixture(V21_FIXTURE_DIR, V21_FIXTURE_STATE)
	_v22_fixture_path = _write_state_fixture(V22_FIXTURE_DIR, V22_FIXTURE_STATE)
	_v23_fixture_path = _write_state_fixture(V23_FIXTURE_DIR, V23_FIXTURE_STATE)
	_v24_fixture_path = _write_state_fixture(V24_FIXTURE_DIR, V24_FIXTURE_STATE)
	_check_v1_fixture_migrates_through_full_chain()
	_check_v2_fixture_migrates_to_v3()
	_check_v3_fixture_migrates_to_v4()
	_check_v4_fixture_migrates_to_v5()
	_check_v5_fixture_migrates_to_v6()
	_check_v6_fixture_migrates_to_v7()
	_check_v7_fixture_migrates_to_v8()
	_check_v8_fixture_migrates_to_v9()
	_check_v9_fixture_migrates_to_v10()
	_check_v10_fixture_migrates_to_v11()
	_check_v11_fixture_migrates_to_v12()
	_check_v12_state_migrates_to_v13()
	_check_v13_state_migrates_to_v14()
	_check_v13_fixture_migrates_to_v14()
	_check_v13_fixture_loads_through_save_io()
	_check_v14_fixture_migrates_to_v15()
	_check_v14_fixture_loads_through_save_io()
	_check_v15_fixture_migrates_to_v16()
	_check_v15_fixture_loads_through_save_io()
	_check_v17_fixture_migrates_to_v18()
	_check_v17_fixture_loads_through_save_io()
	_check_v18_fixture_migrates_to_v19()
	_check_v18_fixture_loads_through_save_io()
	_check_v19_fixture_migrates_to_v20()
	_check_v19_fixture_loads_through_save_io()
	_check_v20_fixture_migrates_to_v21()
	_check_v20_fixture_loads_through_save_io()
	_check_v21_fixture_migrates_to_v22()
	_check_v21_fixture_loads_through_save_io()
	_check_v22_fixture_migrates_to_v23()
	_check_v22_fixture_loads_through_save_io()
	_check_v23_fixture_migrates_to_v24()
	_check_v23_fixture_loads_through_save_io()
	_check_v23_state_with_empty_combat_blocked_targets_migrates_and_loads()
	_check_v24_fixture_migrates_to_v25()
	_check_v24_fixture_loads_through_save_io()
	_check_dig_find_rng_continuation_survives_save_load_round_trip()
	_check_multi_tile_object_round_trips_through_save_load()
	_check_object_without_orientation_field_loads_unchanged()
	_check_object_with_empty_orientation_field_loads_unchanged()
	_check_state_without_construction_sites_field_loads_unchanged()
	_check_construction_site_round_trips_through_save_load()
	_check_malformed_v21_null_needs_is_rejected()
	_check_malformed_v21_array_needs_is_rejected()
	_check_malformed_v21_scalar_needs_is_rejected()
	_check_malformed_v21_null_needs_rejected_through_save_io()
	_check_malformed_v21_array_needs_rejected_through_save_io()
	_check_malformed_v21_scalar_needs_rejected_through_save_io()
	_check_malformed_v20_dictionary_tick_is_rejected()
	_check_malformed_v20_array_tick_is_rejected()
	_check_malformed_v20_tick_rejected_through_save_io()
	_check_incident_scheduler_continuation_survives_save_load_round_trip()
	_check_content_version_mismatch_without_rename_fails()
	_check_content_version_mismatch_resolved_by_rename_loads()
	_check_wall_content_rename_migrates_to_wooden_wall()
	_check_pretask_wall_construction_site_continues_as_wooden_wall_after_load()
	_check_legacy_wall_build_job_synthesizes_wooden_wall_site_via_content_rename()
	_check_wall_rename_missing_objects_field_rejected_through_save_io()
	_check_wall_rename_missing_jobs_field_rejected_through_save_io()
	_check_wall_rename_missing_content_version_rejected_through_save_io()
	_check_wall_rename_invalid_content_version_type_rejected_through_save_io()
	_check_wall_rename_invalid_objects_container_rejected_through_save_io()
	_check_wall_rename_invalid_objects_entry_rejected_through_save_io()
	_check_wall_rename_invalid_construction_sites_container_rejected_through_save_io()
	_check_wall_rename_invalid_construction_sites_entry_rejected_through_save_io()
	_check_wall_rename_invalid_jobs_container_rejected_through_save_io()
	_check_wall_rename_invalid_jobs_entry_rejected_through_save_io()
	_check_wall_rename_non_string_object_kind_rejected_through_save_io()
	_check_wall_rename_non_string_construction_site_kind_rejected_through_save_io()
	_check_wall_rename_non_string_job_build_kind_rejected_through_save_io()
	_check_calendar_alerts_fired_accepts_valid_non_lowercase_id()
	_check_legacy_build_job_loads_through_save_io()
	_check_non_default_labour_table_survives_save_load_round_trip()
	_check_mine_job_and_stone_item_survive_save_load_round_trip()
	_check_non_default_faction_and_health_survive_save_load_round_trip()
	_check_critical_interrupt_survives_save_load_round_trip()
	_check_v1_fixture_loads_through_save_io()
	_check_v2_fixture_loads_through_save_io()
	_check_v3_fixture_loads_through_save_io()
	_check_v4_fixture_loads_through_save_io()
	_check_v5_fixture_loads_through_save_io()
	_check_v6_fixture_loads_through_save_io()
	_check_v7_fixture_loads_through_save_io()
	_check_v8_fixture_loads_through_save_io()
	_check_v9_fixture_loads_through_save_io()
	_check_v10_fixture_loads_through_save_io()
	_check_v11_fixture_loads_through_save_io()
	_check_malformed_v1_entities_are_rejected()
	_check_malformed_v2_entities_are_rejected()
	_check_malformed_v2_assignments_are_rejected()
	_check_malformed_v5_ground_item_target_is_rejected()
	_check_malformed_v5_negative_wood_is_rejected()
	_check_unrecognized_version()
	_cleanup_dir(V13_FIXTURE_DIR)
	_cleanup_dir(V14_FIXTURE_DIR)
	_cleanup_dir(V17_FIXTURE_DIR)
	_cleanup_dir(V19_FIXTURE_DIR)
	_cleanup_dir(V21_FIXTURE_DIR)
	_cleanup_dir(V22_FIXTURE_DIR)
	_cleanup_dir(V23_FIXTURE_DIR)
	_cleanup_dir(V24_FIXTURE_DIR)
	if _failed:
		quit(1)
		return
	print("test_save_migration: PASS")
	quit()

## Writes state to a user:// file as a real save envelope, hashed exactly the
## way SaveIO.write_atomic() hashes its own body (JSON.stringify, then a round
## trip through JSON.parse_string, since that is the form SaveIO.read()
## re-hashes on the way back in) -- write_atomic() itself can't be reused here
## since it validates against the current schema/content version, rejecting a
## deliberately older-schema or mismatched-content-version fixture outright.
func _write_state_fixture(dir_path: String, state: Dictionary) -> String:
	var dir := DirAccess.open("user://")
	if not dir.dir_exists(dir_path):
		dir.make_dir_recursive(dir_path)
	var path := dir_path + "/fixture.json"
	var body := JSON.stringify(state)
	var round_tripped = JSON.parse_string(body)
	var hash := SaveIOType._sha256(JSON.stringify(round_tripped).to_utf8_buffer())
	var envelope := {"format": SaveIOType.FORMAT, "integrity": hash, "state": state}
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()
	return path

func _cleanup_dir(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir_path))

func _load_fixture_state(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	var envelope: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
	var state: Dictionary = envelope["state"]
	SaveIOType._coerce_ints(state)
	return state

## The v1 fixture must reach the current schema (4) via the full
## v1->v2->v3->v4 chain: fresh scheduler/RNG continuation from v1->v2,
## groundItems and per-entity route/work from v2->v3, then empty objects
## from v3->v4.
func _check_v1_fixture_migrates_through_full_chain() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V1)
	var result := SaveMigrationsType.migrate(raw_state, 1, 4)
	_expect(result["ok"], "schemaVersion-1 fixture must migrate to schemaVersion 4: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 4, "fixture must migrate to schemaVersion 4")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs"]:
		_expect(state[key] == raw_state[key], "migration must preserve v1 field '%s'" % key)
	_expect(state["seed"] == 12345 and state["tick"] == 7, "version-1 fields must be preserved")
	_expect(state["inventory"] == {"ore": 3}, "inventory must be preserved")
	_expect(state["jobs"].size() == 1 and state["jobs"][0]["id"] == "job-1", "jobs must be preserved")
	_expect(state["groundItems"] == [], "v1-originated save must migrate with empty groundItems")
	_expect(state["objects"] == [], "v1-originated save must migrate with empty objects")
	_check_entities_carry_null_route_and_work(state["entities"], raw_state["entities"])

	var scheduling: Dictionary = state["scheduling"]
	for key in ["nextJobId", "jobSequence", "jobTick", "queueEventSequence", "eventSequence",
			"waiting", "nextOrdinal", "cursors", "pending", "assignments"]:
		_expect(scheduling.has(key), "migrated scheduling must include %s" % key)
	_expect(scheduling["nextJobId"] == 1 and scheduling["jobSequence"] == 0 and scheduling["jobTick"] == 0,
		"migrated scheduling counters must be fresh")
	_expect(scheduling["queueEventSequence"] == -1 and scheduling["eventSequence"] == 0,
		"migrated event counters must be fresh")
	_expect(scheduling["waiting"].is_empty() and scheduling["cursors"].is_empty()
		and scheduling["pending"].is_empty() and scheduling["assignments"].is_empty(),
		"migrated scheduling collections must be empty")
	var expected_rng := RandomNumberGenerator.new()
	expected_rng.seed = 12345
	var rng: Dictionary = state["rng"]
	_expect(rng["seed"] == expected_rng.seed and rng["state"] == expected_rng.state,
		"migrated RNG must be freshly seeded from the save seed")

## The v2 fixture (no trees/groundItems/route/work) must migrate straight to
## schemaVersion 3 with groundItems == [], every entity carrying route/work,
## and any existing scheduling.assignments entry backfilled with path: [].
func _check_v2_fixture_migrates_to_v3() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V2)
	var result := SaveMigrationsType.migrate(raw_state, 2, 3)
	_expect(result["ok"], "schemaVersion-2 fixture must migrate to schemaVersion 3: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 3, "v2 fixture must migrate to schemaVersion 3")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs"]:
		_expect(state[key] == raw_state[key], "migration must preserve v2 field '%s'" % key)
	_expect(state["groundItems"] == [], "v2-originated save must migrate with empty groundItems")
	_check_entities_carry_null_route_and_work(state["entities"], raw_state["entities"])

	var scheduling: Dictionary = state["scheduling"]
	var raw_scheduling: Dictionary = raw_state["scheduling"]
	for key in ["nextJobId", "jobSequence", "jobTick", "queueEventSequence", "eventSequence",
			"waiting", "nextOrdinal", "cursors", "pending"]:
		_expect(scheduling[key] == raw_scheduling[key], "migration must preserve v2 scheduling field '%s'" % key)
	var assignments: Dictionary = scheduling["assignments"]
	var raw_assignments: Dictionary = raw_scheduling["assignments"]
	_expect(assignments.size() == raw_assignments.size(), "migration must preserve assignment count")
	for worker in raw_assignments.keys():
		var assignment: Dictionary = assignments[worker]
		var raw_assignment: Dictionary = raw_assignments[worker]
		_expect(assignment["jobId"] == raw_assignment["jobId"]
			and assignment["startedTick"] == raw_assignment["startedTick"]
			and assignment["travelTicks"] == raw_assignment["travelTicks"],
			"migration must preserve assignment fields for '%s'" % worker)
		_expect(assignment["path"] == [], "v2-originated assignment must be backfilled with an empty path")
	_expect(state["rng"] == raw_state["rng"], "v2-originated save must preserve rng unchanged")

## The v3 fixture (no objects) must migrate straight to schemaVersion 4 with
## objects == [] and every other field preserved untouched.
func _check_v3_fixture_migrates_to_v4() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V3)
	var result := SaveMigrationsType.migrate(raw_state, 3, 4)
	_expect(result["ok"], "schemaVersion-3 fixture must migrate to schemaVersion 4: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 4, "fixture must migrate to schemaVersion 4")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng", "groundItems"]:
		_expect(state[key] == raw_state[key], "migration must preserve v3 field '%s'" % key)
	_expect(state["objects"] == [], "v3-originated save must migrate with empty objects")

## The v4 fixture (a colonist with a normal, non-rerouting route) must migrate
## straight to schemaVersion 5 with every field preserved unchanged: version 4
## predates re-routing, so the existing route was truthfully already in its
## normal state and the schemaVersion-5 "rerouting" field stays absent (see
## StateCodec._encode_route_field()), not backfilled with an explicit value.
func _check_v4_fixture_migrates_to_v5() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V4)
	var result := SaveMigrationsType.migrate(raw_state, 4, 5)
	_expect(result["ok"], "schemaVersion-4 fixture must migrate to schemaVersion 5: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 5, "v4 fixture must migrate to schemaVersion 5")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs",
			"scheduling", "rng", "groundItems", "objects"]:
		_expect(state[key] == raw_state[key], "migration must preserve v4 field '%s'" % key)
	var route: Dictionary = state["entities"][0]["route"]
	_expect(not route.has("rerouting") or route["rerouting"] == null,
		"a migrated v4 route must default to its normal, non-rerouting state")

## The v5 fixture's groundItems ({x:1,y:1,wood:3}, {x:2,y:0,wood:1}) must
## migrate straight to schemaVersion 6 as one first-class item per unit of
## wood: 3 items at (1,1), 1 item at (2,0), each count 1 kind "wood", with a
## stable, non-colliding id scheme (item_1.. in groundItems' own order) and
## itemsNextId continuing right after the last id handed out. Every entity
## must also be backfilled with carrying: null (version 5 predates it).
func _check_v5_fixture_migrates_to_v6() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V5)
	var result := SaveMigrationsType.migrate(raw_state, 5, 6)
	_expect(result["ok"], "schemaVersion-5 fixture must migrate to schemaVersion 6: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 6, "v5 fixture must migrate to schemaVersion 6")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "scheduling", "rng", "objects"]:
		_expect(state[key] == raw_state[key], "migration must preserve v5 field '%s'" % key)
	_expect(not state.has("groundItems"), "migrated state must drop the old groundItems key")
	var items: Dictionary = state["items"]
	var list: Array = items["list"]
	_expect(list.size() == 4, "one item per unit of wood must be created (got %d)" % list.size())
	var ids := {}
	var at_1_1 := 0
	var at_2_0 := 0
	for item in list:
		_expect(String(item["kind"]) == "wood" and int(item["count"]) == 1,
			"every migrated item must be a count-1 wood item: %s" % item)
		_expect(not ids.has(item["id"]), "every migrated item id must be unique: %s" % item["id"])
		ids[item["id"]] = true
		if int(item["x"]) == 1 and int(item["y"]) == 1:
			at_1_1 += 1
		elif int(item["x"]) == 2 and int(item["y"]) == 0:
			at_2_0 += 1
		else:
			_expect(false, "migrated item at unexpected position: %s" % item)
	_expect(at_1_1 == 3, "3 wood units at (1,1) must become 3 items (got %d)" % at_1_1)
	_expect(at_2_0 == 1, "1 wood unit at (2,0) must become 1 item (got %d)" % at_2_0)
	_expect(int(items["nextId"]) == 5, "itemsNextId must continue right after the last migrated id (got %d)" % int(items["nextId"]))
	_check_entities_carry_null_carrying(state["entities"])

## The v6 fixture (no zones field) must migrate straight to schemaVersion 7
## with zones backfilled to an honestly empty [] and a fresh nextZoneId of 1:
## version 6 predates player-drawn stockpile zones, so there is truthfully
## nothing to backfill besides an empty zone list.
func _check_v6_fixture_migrates_to_v7() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V6)
	var result := SaveMigrationsType.migrate(raw_state, 6, 7)
	_expect(result["ok"], "schemaVersion-6 fixture must migrate to schemaVersion 7: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 7, "v6 fixture must migrate to schemaVersion 7")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects"]:
		_expect(state[key] == raw_state[key], "migration must preserve v6 field '%s'" % key)
	_expect(state["zones"] == [], "v6-originated save must migrate with an empty zones list")
	_expect(state["nextZoneId"] == 1, "v6-originated save must migrate with a fresh nextZoneId")

## The v7 fixture (a chop job pre-dating the haul job kind) must migrate
## straight to schemaVersion 8 with every existing job backfilled with
## JobQueue.submit_dig()'s own harmless haul defaults: itemId "", cell null,
## retryAt 0, backoffTicks 0 (issue #189).
func _check_v7_fixture_migrates_to_v8() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V7)
	var result := SaveMigrationsType.migrate(raw_state, 7, 8)
	_expect(result["ok"], "schemaVersion-7 fixture must migrate to schemaVersion 8: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 8, "v7 fixture must migrate to schemaVersion 8")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "scheduling", "rng",
			"items", "objects", "zones", "nextZoneId"]:
		_expect(state[key] == raw_state[key], "migration must preserve v7 field '%s'" % key)
	_expect(state["jobs"].size() == raw_state["jobs"].size(), "migration must preserve job count")
	for i in state["jobs"].size():
		var migrated_job: Dictionary = state["jobs"][i]
		var raw_job: Dictionary = raw_state["jobs"][i]
		for key in ["id", "kind", "status", "priority", "target", "reason", "remedy", "blockingJobId"]:
			_expect(migrated_job[key] == raw_job[key], "migration must preserve v7 job field '%s'" % key)
		_expect(migrated_job["itemId"] == "" and migrated_job["cell"] == null
			and migrated_job["retryAt"] == 0 and migrated_job["backoffTicks"] == 0,
			"a migrated v7 job must be backfilled with harmless haul defaults")

## The v8 fixture (colonists with no "needs" field, one active haul job) must
## migrate straight to schemaVersion 9 with every colonist backfilled with a
## full (100) food/water/rest, matching WorldState.NEED_FULL/_full_needs():
## version 8 predates needs, so there is truthfully nothing else to backfill.
func _check_v8_fixture_migrates_to_v9() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V8)
	var result := SaveMigrationsType.migrate(raw_state, 8, 9)
	_expect(result["ok"], "schemaVersion-8 fixture must migrate to schemaVersion 9: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 9, "v8 fixture must migrate to schemaVersion 9")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId"]:
		_expect(state[key] == raw_state[key], "migration must preserve v8 field '%s'" % key)
	_expect(state["entities"].size() == raw_state["entities"].size(), "migration must preserve entity count")
	for i in state["entities"].size():
		var migrated_entity: Dictionary = state["entities"][i]
		var raw_entity: Dictionary = raw_state["entities"][i]
		_expect(migrated_entity["id"] == raw_entity["id"] and migrated_entity["x"] == raw_entity["x"]
			and migrated_entity["y"] == raw_entity["y"] and migrated_entity["carrying"] == raw_entity["carrying"],
			"migration must preserve entity core fields")
		_expect(migrated_entity["needs"] == {"food": 100, "water": 100, "rest": 100},
			"a migrated v8 entity must be backfilled with full food/water/rest")

## The v9 fixture (no groundBerries field) must migrate straight to
## schemaVersion 10 with groundBerries backfilled to an honestly empty []:
## version 9 predates berry bushes and forage (#202), so there is truthfully
## nothing to backfill besides an empty list.
func _check_v9_fixture_migrates_to_v10() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V9)
	var result := SaveMigrationsType.migrate(raw_state, 9, 10)
	_expect(result["ok"], "schemaVersion-9 fixture must migrate to schemaVersion 10: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 10, "v9 fixture must migrate to schemaVersion 10")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId"]:
		_expect(state[key] == raw_state[key], "migration must preserve v9 field '%s'" % key)
	_expect(state["groundBerries"] == [], "v9-originated save must migrate with an empty groundBerries list")

## The v10 fixture (no workProgress/pausedJobs fields) must migrate straight
## to schemaVersion 11 with each backfilled to an honestly empty collection:
## version 10 predates the critical-need interrupt (#205), so no `work` toil
## could ever have been paused mid-tick-count, and there is truthfully
## nothing else to backfill (colonist-ai.md 3.6).
func _check_v10_fixture_migrates_to_v11() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V10)
	var result := SaveMigrationsType.migrate(raw_state, 10, 11)
	_expect(result["ok"], "schemaVersion-10 fixture must migrate to schemaVersion 11: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 11, "v10 fixture must migrate to schemaVersion 11")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng", "items", "objects", "zones", "nextZoneId", "groundBerries"]:
		_expect(state[key] == raw_state[key], "migration must preserve v10 field '%s'" % key)
	_expect(state["workProgress"] == [], "v10-originated save must migrate with an empty workProgress list")
	_expect(state["pausedJobs"] == [], "v10-originated save must migrate with an empty pausedJobs list")

## The v11 fixture (colonists with no "labourTable" field) must migrate
## straight to schemaVersion 12 with every colonist backfilled to the same
## default all-3 labour table (colonist-ai.md 3.2) a freshly spawned colonist
## gets today, matching WorldState.LABOUR_KINDS/_default_labour_table():
## version 11 predates the labour table, so there is truthfully nothing else
## to backfill.
func _check_v11_fixture_migrates_to_v12() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V11)
	var result := SaveMigrationsType.migrate(raw_state, 11, 12)
	_expect(result["ok"], "schemaVersion-11 fixture must migrate to schemaVersion 12: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 12, "v11 fixture must migrate to schemaVersion 12")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "scheduling", "rng", "items",
			"objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs"]:
		_expect(state[key] == raw_state[key], "migration must preserve v11 field '%s'" % key)
	var default_labour_table := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	_expect(state["entities"].size() == raw_state["entities"].size(), "migration must preserve entity count")
	for i in state["entities"].size():
		var migrated_entity: Dictionary = state["entities"][i]
		var raw_entity: Dictionary = raw_state["entities"][i]
		_expect(migrated_entity["id"] == raw_entity["id"] and migrated_entity["x"] == raw_entity["x"]
			and migrated_entity["y"] == raw_entity["y"] and migrated_entity["needs"] == raw_entity["needs"]
			and migrated_entity["carrying"] == raw_entity["carrying"],
			"migration must preserve entity core fields")
		_expect(migrated_entity["labourTable"] == default_labour_table,
			"a migrated v11 entity must be backfilled with the default all-3 labour table")

## No schemaVersion-12 fixture file exists (task #213 is the first to reach
## schemaVersion 13), so this exercises SaveMigrations.migrate() straight from
## an inline schemaVersion-12 Dictionary literal (no toolItems/
## toolReservations keys, no entity heldTool): version 12 predates tool items
## (#213), so no axe/pick could ever have existed, and there is truthfully
## nothing else to backfill besides two honestly empty collections
## (colonist-ai.md 2/3.4).
func _check_v12_state_migrates_to_v13() -> void:
	var raw_state := {
		"schemaVersion": 12, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"]},
		"entities": [{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 100, "water": 100, "rest": 100},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null,
		}],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [],
	}
	var result := SaveMigrationsType.migrate(raw_state, 12, 13)
	_expect(result["ok"], "schemaVersion-12 state must migrate to schemaVersion 13: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 13, "v12 state must migrate to schemaVersion 13")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "scheduling", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs"]:
		_expect(state[key] == raw_state[key], "migration must preserve v12 field '%s'" % key)
	_expect(state["toolItems"] == {"nextId": 1, "list": []}, "v12-originated save must migrate with empty toolItems")
	_expect(state["toolReservations"] == {}, "v12-originated save must migrate with empty toolReservations")
	_expect(not (state["entities"][0] as Dictionary).has("heldTool"),
		"a migrated v12 entity must leave heldTool absent, not backfilled")
	# schemaVersion 13 is no longer current (see _check_v14_fixture_migrates_to_v15(),
	# which carries the "passes SaveIO's current-schema validation" check now):
	# validating this intermediate step's output against the current schema
	# would only ever fail on schemaVersion alone, telling us nothing about
	# whether this step's own migration is correct.

## No schemaVersion-13 fixture file exists (#241 review round 2 is the first
## to reach schemaVersion 14), so this exercises SaveMigrations.migrate()
## straight from an inline schemaVersion-13 Dictionary literal whose queue
## entries (waiting, a pending candidate, and a pending found pair) predate
## "restrictTo": version 13 predates both NeedGiver's own persisted
## colonist_id -> job_id association and the queue entry's worker
## restriction (colonist-ai.md 3.1/3.6), so there is truthfully nothing to
## backfill besides an honestly empty needJobAssignments list, "" for every
## existing queue entry's new restrictTo field, and an honestly empty
## activatedEntries map (no v13 save ever tracked a job's original
## waiting-queue entry past its own activation).
func _check_v13_state_migrates_to_v14() -> void:
	var job_entry := {"id": "job_1", "target": {"x": 2, "y": 2}, "base": 5, "submittedTick": 0, "ordinal": 0}
	var raw_state := {
		"schemaVersion": 13, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 3, "height": 3, "tiles": ["soil", "soil", "soil", "soil", "soil", "soil", "soil", "soil", "soil"]},
		"entities": [{
			"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
			"needs": {"food": 100, "water": 100, "rest": 100},
			"labourTable": {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3},
			"route": null, "work": null, "carrying": null,
		}],
		"inventory": {},
		"jobs": [{
			"id": "job_1", "kind": "dig", "status": "queued", "priority": 1, "target": {"x": 2, "y": 2},
			"reason": "", "remedy": "", "blockingJobId": "", "itemId": "", "cell": null,
			"retryAt": 0, "backoffTicks": 0,
		}],
		"scheduling": {
			"nextJobId": 2, "jobSequence": 1, "jobTick": 1, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [job_entry], "nextOrdinal": 1, "cursors": {},
			"pending": {
				"colonist_0": {
					"candidates": [job_entry], "cursor": 0,
					"found": [{"worker": "colonist_0", "entry": job_entry, "travel": 3}],
					"start": {"x": 0, "y": 0}, "route": null,
				},
			},
			"assignments": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 1, "list": []},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [],
		"toolItems": {"nextId": 1, "list": []}, "toolReservations": {},
	}
	var result := SaveMigrationsType.migrate(raw_state, 13, 14)
	_expect(result["ok"], "schemaVersion-13 state must migrate to schemaVersion 14: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 14, "v13 state must migrate to schemaVersion 14")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations"]:
		_expect(state[key] == raw_state[key], "migration must preserve v13 field '%s'" % key)
	_expect(state["needJobAssignments"] == [], "v13-originated save must migrate with an empty needJobAssignments list")

	var scheduling: Dictionary = state["scheduling"]
	_expect(scheduling["activatedEntries"] == {}, "v13-originated save must migrate with an empty activatedEntries map")
	_expect((scheduling["waiting"] as Array).size() == 1, "migration must preserve the waiting entry count")
	_expect(String((scheduling["waiting"][0] as Dictionary).get("restrictTo", "not-present")) == "",
		"a migrated v13 waiting entry must be backfilled with restrictTo: ''")
	var pending: Dictionary = scheduling["pending"]
	var candidate: Dictionary = (pending["colonist_0"]["candidates"] as Array)[0]
	_expect(String(candidate.get("restrictTo", "not-present")) == "",
		"a migrated v13 pending candidate must be backfilled with restrictTo: ''")
	var found_entry: Dictionary = (pending["colonist_0"]["found"] as Array)[0]
	_expect(String((found_entry["entry"] as Dictionary).get("restrictTo", "not-present")) == "",
		"a migrated v13 pending found entry must be backfilled with restrictTo: ''")

	# schemaVersion 14 is no longer current, so this step's own output is
	# advanced through the v14->v16 steps before validating against the
	# current schema -- otherwise the check would only ever fail on
	# schemaVersion alone, telling us nothing about whether this step's own
	# migration is correct.
	var advanced := SaveMigrationsType.migrate(state, 14, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v13 state must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v13 state must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## #243: a real schema-13 save file (as opposed to the inline literal above),
## written to disk by _write_v13_fixture() so this and the next check load it
## the same way an actual pre-objective save would -- two colonists with
## needs/labourTable/heldTool/carrying, a held tool item, ground
## items/berries/objects/zones, partial workProgress, and a pausedJobs entry,
## but no needJobAssignments, no queue-entry restrictTo, and no
## activatedEntries (all three postdate #241 round 2) -- must still migrate
## straight to schemaVersion 14 with every pre-existing field preserved and
## the three new fields honestly backfilled, exactly like the inline v13 case
## above.
func _check_v13_fixture_migrates_to_v14() -> void:
	var raw_state := _load_fixture_state(_v13_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 13, 14)
	_expect(result["ok"], "schemaVersion-13 fixture must migrate to schemaVersion 14: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 14, "v13 fixture must migrate to schemaVersion 14")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations"]:
		_expect(state[key] == raw_state[key], "migration must preserve v13 fixture field '%s'" % key)
	_expect(state["needJobAssignments"] == [], "v13 fixture must migrate with an empty needJobAssignments list")
	var scheduling: Dictionary = state["scheduling"]
	_expect(scheduling["activatedEntries"] == {}, "v13 fixture must migrate with an empty activatedEntries map")
	_expect(scheduling["waiting"] == [], "v13 fixture's empty waiting queue must stay empty after migration")

	# schemaVersion 14 is no longer current, so this step's own output is
	# advanced through the v14->v16 steps before validating against the
	# current schema -- see _check_v13_state_migrates_to_v14()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 14, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v13 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v13 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v13 fixture is not just migration-shaped but an actually
## loadable save envelope (mirroring every _check_vN_fixture_loads_through_save_io()
## above): SaveIO.read() must independently verify its integrity hash,
## migrate it to schemaVersion 14, and pass the current schema's
## _validate_state -- including its carried item, held tool, and non-default
## labourTable, none of which any earlier fixture exercises together.
func _check_v13_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v13_fixture_path)
	_expect(result["ok"], "v13 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v13 fixture must report the current schemaVersion")
	_expect(state["needJobAssignments"] == [], "SaveIO-loaded v13 fixture must carry an empty needJobAssignments list")
	_expect(state["scheduling"]["activatedEntries"] == {}, "SaveIO-loaded v13 fixture must carry an empty activatedEntries map")
	var entities: Array = state["entities"]
	_expect(entities.size() == 2, "SaveIO-loaded v13 fixture must keep both colonists")
	var colonist_1 := {}
	for entity in entities:
		if String(entity["id"]) == "colonist_1":
			colonist_1 = entity
	_expect(colonist_1.get("hands") == [{"kind": "wood", "count": 1}],
		"SaveIO-loaded v13 fixture must keep colonist_1's carried item")
	_expect(state["toolItems"]["list"].size() == 1, "SaveIO-loaded v13 fixture must keep its one tool item")
	_expect(state["pausedJobs"].size() == 1, "SaveIO-loaded v13 fixture must keep its pausedJobs entry")

## #257: the v14 fixture (needJobAssignments and restrictTo genuinely
## populated, unlike the v13 fixture's honestly-empty backfills) must migrate
## straight to schemaVersion 15 with every field preserved unchanged: v14's
## own shape is already the v15 shape, so only the version counter moves.
func _check_v14_fixture_migrates_to_v15() -> void:
	var raw_state := _load_fixture_state(_v14_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 14, 15)
	_expect(result["ok"], "schemaVersion-14 fixture must migrate to schemaVersion 15: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 15, "v14 fixture must migrate to schemaVersion 15")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling"]:
		_expect(state[key] == raw_state[key], "migration must preserve v14 fixture field '%s'" % key)

	# schemaVersion 15 is no longer current, so this step's own output is
	# advanced through the v15->v16 step before validating against the
	# current schema -- see _check_v13_state_migrates_to_v14()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 15, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v14 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v14 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v14 fixture is not just migration-shaped but an actually
## loadable save envelope: SaveIO.read() must independently verify its
## integrity hash, migrate it to schemaVersion 15, and pass the current
## schema's _validate_state -- including its populated needJobAssignments
## entry and non-empty queue-entry restrictTo/activatedEntries, none of which
## the v13 fixture's honestly-empty backfills exercise.
func _check_v14_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v14_fixture_path)
	_expect(result["ok"], "v14 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v14 fixture must report the current schemaVersion")
	_expect(state["needJobAssignments"] == [{"colonistId": "colonist_0", "jobId": "job_1"}],
		"SaveIO-loaded v14 fixture must keep its needJobAssignments entry")
	_expect(state["scheduling"]["activatedEntries"].has("job_1"),
		"SaveIO-loaded v14 fixture must keep its activatedEntries entry")
	var waiting: Array = state["scheduling"]["waiting"]
	_expect(waiting.size() == 1 and String(waiting[0]["restrictTo"]) == "colonist_0",
		"SaveIO-loaded v14 fixture must keep its waiting entry's restrictTo")

## #269: the v15 fixture (a real save predating the sowing-window calendar
## alert, ADR 008 consequence 6) must migrate straight to schemaVersion 16
## with every pre-existing field preserved and calendarAlerts honestly
## backfilled to {fired: []} -- no window could ever have fired on a save
## this old -- and the result must validate against the current schema
## (docs/architecture/contracts/game-state.schema.json, mirrored here by
## SaveIOType._validate_state() per this file's own header docstring).
func _check_v15_fixture_migrates_to_v16() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V16)
	var result := SaveMigrationsType.migrate(raw_state, 15, 16)
	_expect(result["ok"], "schemaVersion-15 fixture must migrate to schemaVersion 16: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 16, "v15 fixture must migrate to schemaVersion 16")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling"]:
		_expect(state[key] == raw_state[key], "migration must preserve v15 fixture field '%s'" % key)
	_expect(state["calendarAlerts"] == {"fired": []}, "v15 fixture must migrate with calendarAlerts backfilled to fired: []")

	# schemaVersion 16 is no longer current, so this step's own output is
	# advanced through the v16->v17 step before validating against the
	# current schema -- see _check_v13_state_migrates_to_v14()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 16, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v15 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v15 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v15 fixture is not just migration-shaped but an actually
## loadable save envelope (mirroring every _check_vN_fixture_loads_through_save_io()
## above): SaveIO.read() must independently verify its integrity hash,
## migrate it all the way to the current schema, and pass the current
## schema's _validate_state, including its honestly-backfilled calendarAlerts.
func _check_v15_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V16)
	_expect(result["ok"], "v15 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v15 fixture must report the current schemaVersion")
	_expect(state["calendarAlerts"] == {"fired": []},
		"SaveIO-loaded v15 fixture must carry calendarAlerts backfilled to fired: []")

## #284: the v17 fixture (a real save predating per-actor faction membership
## and persisted colonist health) must migrate straight to schemaVersion 18
## with every pre-existing field preserved and every entity honestly
## backfilled with factionId: "colony" and a full-health snapshot
## {hp: 100, maxHp: 100, dead: false} -- no entity could ever have belonged to
## another faction or had its real hp restored across a save/load round trip
## on a save this old -- and the result must validate against the current
## schema (docs/architecture/contracts/game-state.schema.json, mirrored here
## by SaveIOType._validate_state() per this file's own header docstring).
func _check_v17_fixture_migrates_to_v18() -> void:
	var raw_state := _load_fixture_state(_v17_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 17, 18)
	_expect(result["ok"], "schemaVersion-17 fixture must migrate to schemaVersion 18: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 18, "v17 fixture must migrate to schemaVersion 18")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded"]:
		_expect(state[key] == raw_state[key], "migration must preserve v17 fixture field '%s'" % key)
	_expect(state["entities"].size() == raw_state["entities"].size(), "migration must preserve entity count")
	for i in state["entities"].size():
		var migrated_entity: Dictionary = state["entities"][i]
		var raw_entity: Dictionary = raw_state["entities"][i]
		for key in ["id", "kind", "x", "y", "needs", "labourTable", "route", "work", "carrying", "heldTool"]:
			_expect(migrated_entity[key] == raw_entity[key], "migration must preserve v17 entity field '%s'" % key)
		_expect(migrated_entity["factionId"] == "colony",
			"a migrated v17 entity must be backfilled with factionId: 'colony'")
		_expect(migrated_entity["health"] == {"hp": 100, "maxHp": 100, "dead": false},
			"a migrated v17 entity must be backfilled with a full-health snapshot")

	# schemaVersion 18 is no longer current, so this step's own output is
	# advanced through the v18->v19 step before validating against the
	# current schema -- see _check_v13_state_migrates_to_v14()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 18, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v17 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v17 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v17 fixture is not just migration-shaped but an actually
## loadable save envelope (mirroring every _check_vN_fixture_loads_through_save_io()
## above): SaveIO.read() must independently verify its integrity hash,
## migrate it to schemaVersion 18, and pass the current schema's
## _validate_state -- including its honestly-backfilled factionId/health,
## its held tool, and its carried item.
func _check_v17_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v17_fixture_path)
	_expect(result["ok"], "v17 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v17 fixture must report the current schemaVersion")
	for entity in (state["entities"] as Array):
		_expect(String((entity as Dictionary).get("factionId", "")) == "colony",
			"SaveIO-loaded v17 fixture entity must carry factionId backfilled to 'colony'")
		_expect((entity as Dictionary).get("health") == {"hp": 100, "maxHp": 100, "dead": false},
			"SaveIO-loaded v17 fixture entity must carry health backfilled to a full-health snapshot")
	_expect(state["calendarAlerts"] == {"fired": ["SpringSow"]},
		"SaveIO-loaded v17 fixture must keep its fired calendar alert")
	_expect(state["toolFetchExcluded"] == [{"jobId": "job_1", "toolIds": ["tool_1"]}],
		"SaveIO-loaded v17 fixture must keep its toolFetchExcluded entry")

## #288: the v18 fixture (a real save predating per-object/per-item faction
## ownership) must migrate straight to schemaVersion 19 with every
## pre-existing field preserved and every item and object honestly backfilled
## with factionId: "colony" -- no object or item could ever have belonged to
## another faction on a save this old (StateCodec's own encode() never wrote
## the field before this version) -- and the result must validate against the
## current schema (docs/architecture/contracts/game-state.schema.json,
## mirrored here by SaveIOType._validate_state() per this file's own header
## docstring).
func _check_v18_fixture_migrates_to_v19() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V18)
	var result := SaveMigrationsType.migrate(raw_state, 18, 19)
	_expect(result["ok"], "schemaVersion-18 fixture must migrate to schemaVersion 19: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 19, "v18 fixture must migrate to schemaVersion 19")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded"]:
		_expect(state[key] == raw_state[key], "migration must preserve v18 fixture field '%s'" % key)

	var raw_items: Array = raw_state["items"]["list"]
	var migrated_items: Array = state["items"]["list"]
	_expect(state["items"]["nextId"] == raw_state["items"]["nextId"], "migration must preserve items.nextId")
	_expect(migrated_items.size() == raw_items.size() and migrated_items.size() >= 2,
		"migration must preserve item count")
	for i in migrated_items.size():
		var migrated_item: Dictionary = migrated_items[i]
		var raw_item: Dictionary = raw_items[i]
		for key in ["id", "x", "y", "kind", "count"]:
			_expect(migrated_item[key] == raw_item[key], "migration must preserve v18 item field '%s'" % key)
		_expect(migrated_item["factionId"] == "colony", "a migrated v18 item must be backfilled with factionId: 'colony'")

	var raw_objects: Array = raw_state["objects"]
	var migrated_objects: Array = state["objects"]
	_expect(migrated_objects.size() == raw_objects.size() and migrated_objects.size() >= 2,
		"migration must preserve object count")
	for i in migrated_objects.size():
		var migrated_object: Dictionary = migrated_objects[i]
		var raw_object: Dictionary = raw_objects[i]
		for key in ["target", "kind"]:
			_expect(migrated_object[key] == raw_object[key], "migration must preserve v18 object field '%s'" % key)
		_expect(migrated_object["factionId"] == "colony", "a migrated v18 object must be backfilled with factionId: 'colony'")

	_expect(state["entities"] == raw_state["entities"], "migration must not disturb v18 entities")

	# schemaVersion 19 is no longer current, so this step's own output is
	# advanced through the v19->v20 step before validating against the
	# current schema -- see _check_v17_fixture_migrates_to_v18()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 19, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v18 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v18 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v18 fixture is not just migration-shaped but an actually
## loadable save envelope (mirroring every _check_vN_fixture_loads_through_save_io()
## above): SaveIO.read() must independently verify its integrity hash,
## migrate it to schemaVersion 19, and pass the current schema's
## _validate_state -- including every item's and object's honestly-backfilled
## factionId.
func _check_v18_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V18)
	_expect(result["ok"], "v18 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v18 fixture must report the current schemaVersion")
	var items: Array = state["items"]["list"]
	_expect(items.size() >= 2, "SaveIO-loaded v18 fixture must keep its items")
	for item in items:
		_expect(String((item as Dictionary).get("factionId", "")) == "colony",
			"SaveIO-loaded v18 fixture item must carry factionId backfilled to 'colony'")
	var objects: Array = state["objects"]
	_expect(objects.size() >= 2, "SaveIO-loaded v18 fixture must keep its objects")
	for object_entry in objects:
		_expect(String((object_entry as Dictionary).get("factionId", "")) == "colony",
			"SaveIO-loaded v18 fixture object must carry factionId backfilled to 'colony'")

## #299 (ADR 019): a v19 save predates "map.generatorVersion" -- migration
## must backfill it to 1 (the only generator algorithm that has ever produced
## a save) while leaving "map.width"/"map.height" and everything else
## byte-for-byte untouched, and the result must validate against the current
## schema.
func _check_v19_fixture_migrates_to_v20() -> void:
	var raw_state := _load_fixture_state(_v19_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 19, 20)
	_expect(result["ok"], "schemaVersion-19 fixture must migrate to schemaVersion 20: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 20, "v19 fixture must migrate to schemaVersion 20")
	for key in ["contentVersion", "seed", "tick", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded"]:
		_expect(state[key] == raw_state[key], "migration must preserve v19 fixture field '%s'" % key)
	var migrated_map: Dictionary = state["map"]
	var raw_map: Dictionary = raw_state["map"]
	_expect(migrated_map["width"] == raw_map["width"] and migrated_map["height"] == raw_map["height"]
			and migrated_map["tiles"] == raw_map["tiles"], "migration must preserve v19 map width/height/tiles")
	_expect(migrated_map["generatorVersion"] == 1, "a migrated v19 map must be backfilled with generatorVersion: 1")
	_expect(int(state.get("epoch", -1)) == 0, "a migrated v19 save must be backfilled with epoch: 0")

	# schemaVersion 20 is no longer current, so this step's own output is
	# advanced through the v20->v21 step before validating against the
	# current schema -- see _check_v17_fixture_migrates_to_v18()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 20, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v19 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v19 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v19 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above: SaveIO.read() must independently verify its integrity hash, migrate
## it to schemaVersion 20, and pass the current schema's _validate_state.
func _check_v19_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v19_fixture_path)
	_expect(result["ok"], "v19 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v19 fixture must report the current schemaVersion")
	_expect(int(state["map"]["generatorVersion"]) == 1, "SaveIO-loaded v19 fixture must carry generatorVersion backfilled to 1")
	_expect(int(state.get("epoch", -1)) == 0, "SaveIO-loaded v19 fixture must carry epoch backfilled to 0")
	_expect(int(state["map"]["width"]) == 3 and int(state["map"]["height"]) == 2,
		"SaveIO-loaded v19 fixture must keep its original map dimensions")
	var decoded := StateCodecType.decode(state)
	_expect(decoded.get_map_width() == 3 and decoded.get_map_height() == 2,
		"a decoded 3x2 v19 fixture must keep its exact saved dimensions, not be re-clamped to WorldGenerator's 16-tile new-game minimum")
	_expect(decoded.get_tiles().size() == 6,
		"a decoded 3x2 v19 fixture must have exactly width*height tiles, not a mismatched 16x16 array")

## #295 (F5, issue #294; ADR 004 "WorldState's diagnostic hash includes this
## continuation state"): a v20 save predates incidents, so migration must
## backfill `incidentScheduler.cooldownUntilDay` to an honestly empty map,
## `lastProcessedDay` to the save's own current calendar day (not 0 -- a
## restored world must not treat every day it never lived through as newly
## due), and `rng` to the exact same deterministic re-seed
## IncidentScheduler._init() itself derives from the save's seed, while every
## pre-existing field is preserved untouched.
func _check_v20_fixture_migrates_to_v21() -> void:
	var raw_state := _load_fixture_state(FIXTURE_V20)
	var result := SaveMigrationsType.migrate(raw_state, 20, 21)
	_expect(result["ok"], "schemaVersion-20 fixture must migrate to schemaVersion 21: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 21, "v20 fixture must migrate to schemaVersion 21")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded", "epoch"]:
		_expect(state[key] == raw_state[key], "migration must preserve v20 fixture field '%s'" % key)

	var incident_scheduler: Dictionary = state["incidentScheduler"]
	_expect(incident_scheduler["cooldownUntilDay"] == {},
		"a migrated v20 save must be backfilled with an honestly empty cooldownUntilDay")
	var expected_day := CalendarServiceType.new().day_of_tick(int(raw_state["tick"]))
	_expect(incident_scheduler["lastProcessedDay"] == expected_day,
		"a migrated v20 save's lastProcessedDay must sync to the save's own current calendar day (%d), got %s" % [expected_day, incident_scheduler["lastProcessedDay"]])
	var expected_random := RandomNumberGenerator.new()
	expected_random.seed = int(raw_state["seed"]) + IncidentSchedulerType.SEED_SALT
	var rng: Dictionary = incident_scheduler["rng"]
	_expect(rng["seed"] == expected_random.seed and rng["state"] == expected_random.state,
		"a migrated v20 save's incidentScheduler.rng must be freshly re-seeded the same way IncidentScheduler._init() derives it")

	# schemaVersion 21 is no longer current, so this step's own output is
	# advanced through the v21->v22 step before validating against the
	# current schema -- see _check_v19_fixture_migrates_to_v20()'s identical
	# reasoning.
	var advanced := SaveMigrationsType.migrate(state, 21, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v20 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v20 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v20 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above: SaveIO.read() must independently verify its integrity hash, migrate
## it to schemaVersion 21, and pass the current schema's _validate_state.
func _check_v20_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V20)
	_expect(result["ok"], "v20 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v20 fixture must report the current schemaVersion")
	_expect(state["incidentScheduler"]["cooldownUntilDay"] == {},
		"SaveIO-loaded v20 fixture must carry an honestly empty incidentScheduler.cooldownUntilDay")

## Issue #349/ADR 023: a v21 save predates the per-need decay accumulator, so
## migration must backfill every entity that already carries "needs" with a
## "needsAccumulator" of 0 for each of that same "needs" dictionary's own
## kinds -- honest, since a v21 save never tracked a sub-point carry to lose
## -- while every other field is preserved untouched.
func _check_v21_fixture_migrates_to_v22() -> void:
	var raw_state := _load_fixture_state(_v21_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 21, 22)
	_expect(result["ok"], "schemaVersion-21 fixture must migrate to schemaVersion 22: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 22, "v21 fixture must migrate to schemaVersion 22 (the fixed step this migration implements)")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded", "epoch", "incidentScheduler"]:
		_expect(state[key] == raw_state[key], "migration must preserve v21 fixture field '%s'" % key)

	var raw_entities: Array = raw_state["entities"]
	var migrated_entities: Array = state["entities"]
	_expect(migrated_entities.size() == raw_entities.size(), "migration must preserve entity count")
	for i in migrated_entities.size():
		var raw_entity: Dictionary = raw_entities[i]
		var migrated_entity: Dictionary = migrated_entities[i]
		_expect(not raw_entity.has("needsAccumulator"), "sanity: the v21 fixture must not already carry needsAccumulator")
		_expect(migrated_entity.has("needsAccumulator"), "a migrated v21 entity with 'needs' must be backfilled with 'needsAccumulator'")
		var accumulator: Dictionary = migrated_entity.get("needsAccumulator", {})
		var needs: Dictionary = raw_entity.get("needs", {})
		_expect(accumulator.keys().size() == needs.keys().size(),
			"a migrated v21 entity's needsAccumulator must cover exactly its own needs kinds")
		for kind in needs.keys():
			_expect(accumulator.has(kind) and int(accumulator[kind]) == 0,
				"a migrated v21 entity's needsAccumulator['%s'] must be honestly backfilled to 0, got %s" % [kind, accumulator.get(kind)])
		for key in migrated_entity.keys():
			if key == "needsAccumulator":
				continue
			_expect(migrated_entity[key] == raw_entity[key], "migration must preserve v21 entity field '%s'" % key)

	# schemaVersion 22 is not guaranteed to stay current, so this step's own
	# output is advanced through to StateCodecType.SCHEMA_VERSION before
	# validating against the current schema -- see _check_v20_fixture_migrates_to_v21()'s
	# identical reasoning; a no-op today while 22 IS current, but keeps this
	# test correct once a later migration adds schemaVersion 23.
	var advanced := SaveMigrationsType.migrate(state, 22, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v21 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v21 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v21 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above: SaveIO.read() must independently verify its integrity hash, migrate
## it to schemaVersion 22, and pass the current schema's _validate_state.
func _check_v21_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v21_fixture_path)
	_expect(result["ok"], "v21 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v21 fixture must report the current schemaVersion")
	for entity in (state["entities"] as Array):
		if not (entity as Dictionary).has("needs"):
			continue
		var accumulator: Dictionary = (entity as Dictionary).get("needsAccumulator", {})
		for kind in ((entity as Dictionary)["needs"] as Dictionary).keys():
			_expect(int(accumulator.get(kind, -1)) == 0,
				"SaveIO-loaded v21 fixture must carry needsAccumulator['%s'] backfilled to 0" % kind)

## Issue #358 round 2 review (ADR 025 amendment): a v22 save predates the
## persisted dig-find RNG continuation, so migration must backfill
## "digFindRng" to the exact same deterministic re-seed WorldState._init()
## itself derives from the save's seed (seed + WorldState.DIG_FIND_SEED_SALT),
## mirroring _check_v20_fixture_migrates_to_v21()'s identical
## incidentScheduler.rng assertion, while every pre-existing field is
## preserved untouched.
func _check_v22_fixture_migrates_to_v23() -> void:
	var raw_state := _load_fixture_state(_v22_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 22, 23)
	_expect(result["ok"], "schemaVersion-22 fixture must migrate to schemaVersion 23: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 23, "v22 fixture must migrate to schemaVersion 23")
	for key in ["contentVersion", "seed", "tick", "map", "entities", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded", "epoch", "incidentScheduler"]:
		_expect(state[key] == raw_state[key], "migration must preserve v22 fixture field '%s'" % key)

	_expect(not raw_state.has("digFindRng"), "sanity: the v22 fixture must not already carry digFindRng")
	var expected_random := RandomNumberGenerator.new()
	expected_random.seed = int(raw_state["seed"]) + WorldStateType.DIG_FIND_SEED_SALT
	var dig_find_rng: Dictionary = state["digFindRng"]
	_expect(dig_find_rng["seed"] == expected_random.seed and dig_find_rng["state"] == expected_random.state,
		"a migrated v22 save's digFindRng must be freshly re-seeded the same way WorldState._init() derives it")

	# schemaVersion 23 is not guaranteed to stay current, so this step's own
	# output is advanced through to StateCodecType.SCHEMA_VERSION before
	# validating against the current schema -- see _check_v20_fixture_migrates_to_v21()'s
	# identical reasoning; a no-op today while 23 IS current, but keeps this
	# test correct once a later migration adds schemaVersion 24.
	var advanced := SaveMigrationsType.migrate(state, 23, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v22 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v22 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v22 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above: SaveIO.read() must independently verify its integrity hash, migrate
## it to schemaVersion 23, and pass the current schema's _validate_state.
func _check_v22_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v22_fixture_path)
	_expect(result["ok"], "v22 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v22 fixture must report the current schemaVersion")
	_expect((state["digFindRng"] as Dictionary).has("seed") and (state["digFindRng"] as Dictionary).has("state"),
		"SaveIO-loaded v22 fixture must carry a backfilled digFindRng")

## Issue #359 (ADR 025 t3): a v23 save predates a trapped actor's persisted
## state, so migration must backfill every entity with "trapped": null --
## mirroring _check_v21_fixture_migrates_to_v22()'s identical needsAccumulator
## assertion shape -- while every other field, including a POPULATED
## "combatBlockedTargets" (round-4 review: a real v23 save from current main
## always carries this key), is preserved untouched.
func _check_v23_fixture_migrates_to_v24() -> void:
	var raw_state := _load_fixture_state(_v23_fixture_path)
	_expect(not (raw_state["combatBlockedTargets"] as Array).is_empty(),
		"sanity: the v23 fixture's combatBlockedTargets must be populated, not empty, to exercise the round-4 regression")
	var result := SaveMigrationsType.migrate(raw_state, 23, 24)
	_expect(result["ok"], "schemaVersion-23 fixture must migrate to schemaVersion 24: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 24, "v23 fixture must migrate to schemaVersion 24")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded", "epoch", "incidentScheduler", "digFindRng", "combatBlockedTargets"]:
		_expect(state[key] == raw_state[key], "migration must preserve v23 fixture field '%s'" % key)

	var raw_entities: Array = raw_state["entities"]
	var migrated_entities: Array = state["entities"]
	_expect(migrated_entities.size() == raw_entities.size(), "migration must preserve entity count")
	for i in migrated_entities.size():
		var raw_entity: Dictionary = raw_entities[i]
		var migrated_entity: Dictionary = migrated_entities[i]
		_expect(not raw_entity.has("trapped"), "sanity: the v23 fixture must not already carry trapped")
		_expect(migrated_entity.has("trapped") and migrated_entity["trapped"] == null,
			"a migrated v23 entity must be backfilled with trapped: null")
		for key in migrated_entity.keys():
			if key == "trapped":
				continue
			_expect(migrated_entity[key] == raw_entity[key], "migration must preserve v23 entity field '%s'" % key)

	# schemaVersion 24 is not guaranteed to stay current, so this step's own
	# output is advanced through to StateCodecType.SCHEMA_VERSION before
	# validating against the current schema -- see _check_v20_fixture_migrates_to_v21()'s
	# identical reasoning; a no-op today while 24 IS current.
	var advanced := SaveMigrationsType.migrate(state, 24, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v23 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v23 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v23 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above: SaveIO.read() must independently verify its integrity hash, migrate
## it to schemaVersion 24, and pass the current schema's _validate_state.
func _check_v23_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v23_fixture_path)
	_expect(result["ok"], "v23 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v23 fixture must report the current schemaVersion")
	for entity in (state["entities"] as Array):
		_expect((entity as Dictionary).get("trapped") == null,
			"SaveIO-loaded v23 fixture must carry a backfilled trapped: null")
	_expect((state["combatBlockedTargets"] as Array).size() == 1,
		"SaveIO-loaded v23 fixture must preserve its populated combatBlockedTargets entry, not drop or reject it")

## Round-4 review: a real schemaVersion-23 save whose "combatBlockedTargets"
## is an honestly EMPTY list (an actor never fled, or its episode already
## closed) is the ordinary case, not just the populated fixture above --
## proves _is_schema_v23_state() accepts the field being present-but-empty
## too, mirroring save_io.gd's own optional treatment of it, and that
## migration leaves it untouched (still [], not dropped) both directly and
## through a real SaveIO.read() round trip.
const V23_EMPTY_COMBAT_BLOCKED_FIXTURE_DIR := "user://test-save-migration-v23-empty-combat-blocked-fixture"

func _check_v23_state_with_empty_combat_blocked_targets_migrates_and_loads() -> void:
	var raw_state: Dictionary = V23_FIXTURE_STATE.duplicate(true)
	raw_state["combatBlockedTargets"] = []
	var result := SaveMigrationsType.migrate(raw_state, 23, 24)
	_expect(result["ok"], "a v23 state with empty combatBlockedTargets must migrate to schemaVersion 24: %s" % result)
	if result["ok"]:
		var state: Dictionary = result["state"]
		_expect((state["combatBlockedTargets"] as Array).is_empty(),
			"migration must preserve an empty combatBlockedTargets as [], never mutate it")
	var fixture_path := _write_state_fixture(V23_EMPTY_COMBAT_BLOCKED_FIXTURE_DIR, raw_state)
	var loaded := SaveIOType.read(fixture_path)
	_expect(loaded["ok"], "a v23 save with empty combatBlockedTargets must load through SaveIO.read(): %s" % loaded)
	if loaded["ok"]:
		_expect((loaded["state"]["combatBlockedTargets"] as Array).is_empty(),
			"SaveIO-loaded empty combatBlockedTargets must stay empty, not be dropped or backfilled with data")
	_cleanup_dir(V23_EMPTY_COMBAT_BLOCKED_FIXTURE_DIR)

## Issue #402 (ADR 035): proves the v24 fixture's null-carrying entity
## migrates to an empty hands array and its populated-carrying entity
## migrates to a one-entry hands array preserving kind/count, with every
## other field (including "trapped", already present since v24) untouched.
func _check_v24_fixture_migrates_to_v25() -> void:
	var raw_state := _load_fixture_state(_v24_fixture_path)
	var result := SaveMigrationsType.migrate(raw_state, 24, 25)
	_expect(result["ok"], "schemaVersion-24 fixture must migrate to schemaVersion 25: %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == 25, "v24 fixture must migrate to schemaVersion 25")
	for key in ["contentVersion", "seed", "tick", "map", "inventory", "jobs", "rng",
			"items", "objects", "zones", "nextZoneId", "groundBerries", "workProgress", "pausedJobs",
			"toolItems", "toolReservations", "needJobAssignments", "scheduling", "calendarAlerts",
			"toolFetchExcluded", "epoch", "incidentScheduler"]:
		_expect(state[key] == raw_state[key], "migration must preserve v24 fixture field '%s'" % key)

	var raw_entities: Array = raw_state["entities"]
	var migrated_entities: Array = state["entities"]
	_expect(migrated_entities.size() == raw_entities.size(), "migration must preserve entity count")

	_expect(not (raw_entities[0] as Dictionary).has("hands"), "sanity: the v24 fixture must not already carry hands")
	var null_carrying_entity: Dictionary = migrated_entities[0]
	_expect(null_carrying_entity.get("hands") == [], "a null-carrying v24 entity must migrate to an empty hands array")
	_expect(not null_carrying_entity.has("carrying"), "migration must remove the legacy carrying field")

	var populated_entity: Dictionary = migrated_entities[1]
	_expect(populated_entity.get("hands") == [{"kind": "wood", "count": 3}],
		"a populated v24 carrying entity must migrate to a one-entry hands array preserving kind/count")
	_expect(not populated_entity.has("carrying"), "migration must remove the legacy carrying field")

	for key in ["id", "kind", "x", "y", "factionId", "health", "needs", "needsAccumulator", "labourTable",
			"route", "work", "heldTool", "trapped"]:
		_expect(migrated_entities[0][key] == raw_entities[0][key], "migration must preserve v24 entity field '%s' (colonist_0)" % key)
		_expect(migrated_entities[1][key] == raw_entities[1][key], "migration must preserve v24 entity field '%s' (colonist_1)" % key)

	var advanced := SaveMigrationsType.migrate(state, 25, StateCodecType.SCHEMA_VERSION)
	_expect(advanced["ok"], "a migrated v24 fixture must further migrate to schemaVersion %d: %s" % [StateCodecType.SCHEMA_VERSION, advanced])
	if not advanced["ok"]:
		return
	var validation := SaveIOType._validate_state(advanced["state"])
	_expect(validation["ok"], "a migrated v24 fixture must pass SaveIO's current-schema validation: %s" % validation.get("message", ""))

## Proves the v24 fixture is not just migration-shaped but an actually
## loadable save envelope, mirroring every _check_vN_fixture_loads_through_save_io()
## above.
func _check_v24_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(_v24_fixture_path)
	_expect(result["ok"], "v24 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v24 fixture must report the current schemaVersion")
	var entities: Array = state["entities"]
	_expect(((entities[0] as Dictionary)["hands"] as Array).is_empty(),
		"SaveIO-loaded v24 fixture's null-carrying entity must have empty hands")
	_expect((entities[1] as Dictionary)["hands"] == [{"kind": "wood", "count": 3}],
		"SaveIO-loaded v24 fixture's populated-carrying entity must have a one-entry hands array")

## Issue #358 round 2 review: proves the dig-find RNG's own continuation --
## a non-freshly-seeded stream (distinct seed and state from a brand-new
## WorldState's own construction-time values) -- survives a real
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() round trip exactly, the same way
## _check_incident_scheduler_continuation_survives_save_load_round_trip()
## proves it for the incident scheduler's own RNG, and that state_hash()
## actually changes when this stream's position differs (so a diverged find
## sequence can never hide behind an unchanged hash).
func _check_dig_find_rng_continuation_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260925, 10)
	var hash_before_draw := world.state_hash()
	world._dig_find_random.seed = 777
	world._dig_find_random.randi() # advances .state away from its fresh-seed default
	var expected_rng_seed: int = world._dig_find_random.seed
	var expected_rng_state: int = world._dig_find_random.state
	_expect(world.state_hash() != hash_before_draw,
		"advancing the dig-find RNG stream must change state_hash(), or a diverged find sequence could hide behind an unchanged hash")

	var saved := world.to_save_state()
	_expect(int(saved["digFindRng"]["seed"]) == expected_rng_seed and int(saved["digFindRng"]["state"]) == expected_rng_state,
		"to_save_state() must encode the live dig-find RNG stream exactly")
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored._dig_find_random.seed == expected_rng_seed and restored._dig_find_random.state == expected_rng_state,
		"a save/load round trip must preserve the dig-find RNG's own stream exactly")
	_expect(restored.state_hash() == world.state_hash(),
		"a save/load round trip must reproduce the exact same state_hash() once the dig-find RNG is restored")

## Issue #405: content/objects.json's "test_footprint_crate" (footprint [2, 1],
## rotatable) placed "vertical" occupies (5, 5) and (5, 6). Proves the full
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() stack persists it as exactly one record naming its
## origin tile and orientation (docs/decisions/037), not one per occupied
## tile, and that a real WorldState reconstructed from that one record
## re-occupies both footprint tiles with a byte-identical state_hash().
func _check_multi_tile_object_round_trips_through_save_load() -> void:
	var world := WorldStateType.new(20260926, 10)
	var origin := Vector2i(5, 5)
	world._tiles[world._tile_index(origin.x, origin.y)] = WorldStateType.TILE_FLOOR
	world._tiles[world._tile_index(origin.x, origin.y + 1)] = WorldStateType.TILE_FLOOR
	world._set_object(origin.x, origin.y, "test_footprint_crate", "colony", "vertical")
	_expect(world.get_object(origin.x, origin.y) == "test_footprint_crate" and world.get_object(origin.x, origin.y + 1) == "test_footprint_crate",
		"setup must occupy both footprint tiles before the round trip")
	var before_hash := world.state_hash()

	var saved := world.to_save_state()
	var footprint_records: Array = []
	for entry in (saved["objects"] as Array):
		if String((entry as Dictionary).get("kind", "")) == "test_footprint_crate":
			footprint_records.append(entry)
	_expect(footprint_records.size() == 1, "a multi-tile object must persist as exactly one record, not one per occupied tile")
	if footprint_records.size() == 1:
		var record: Dictionary = footprint_records[0]
		_expect(record["target"] == {"x": origin.x, "y": origin.y}, "the persisted record must name the object's origin tile")
		_expect(String(record.get("orientation", "")) == "vertical", "the persisted record must carry the placed orientation")

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored.get_object(origin.x, origin.y) == "test_footprint_crate" and restored.get_object(origin.x, origin.y + 1) == "test_footprint_crate",
		"a restored multi-tile object must occupy both footprint tiles")
	_expect(restored.state_hash() == before_hash, "a multi-tile object must round-trip with an unchanged state_hash()")

## Issue #405: game-state.schema.json's "orientation" field is optional --
## absent means footprint [1,1]/no rotation, so a current-schema-version save
## written before this task (no object entry ever named it) must still
## validate and decode unchanged, exactly like objects[].health/
## route.rerouting's own optional-field precedent.
func _check_object_without_orientation_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "wall", "factionId": "colony"}]
	var validation := SaveIOType._validate_state(state)
	_expect(validation["ok"], "a current-schema object entry with no orientation field must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_object(0, 0) == "wall", "decode() must restore an object entry with no orientation field")
	_expect(world.get_object_faction_id(0, 0) == "colony", "decode() must restore its factionId")

## Issue #405 review round 1: an explicit orientation: "" must validate and
## decode identically to the field's absence -- "" is the same "no rotation"
## default, not a third distinct value, so SaveIO._valid_object() and the
## schema must both accept it (previously only "horizontal"/"vertical" were
## legal, rejecting a save that wrote "" explicitly).
func _check_object_with_empty_orientation_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "wall", "factionId": "colony", "orientation": ""}]
	var validation := SaveIOType._validate_state(state)
	_expect(validation["ok"], "a current-schema object entry with orientation '' must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_object(0, 0) == "wall", "decode() must restore an object entry with orientation ''")
	_expect(world.get_object_faction_id(0, 0) == "colony", "decode() must restore its factionId")

## Issue #406: game-state.schema.json's "constructionSites" top-level field is
## optional -- absent means no active construction sites, so a current-schema-
## version save written before this task (no such field at all) must still
## validate and decode unchanged, exactly like objects[].orientation's own
## optional-field precedent above.
func _check_state_without_construction_sites_field_loads_unchanged() -> void:
	var state := _minimal_current_schema_state("test-content", "wood")
	_expect(not state.has("constructionSites"), "the minimal fixture must genuinely omit constructionSites for this to be a real proof")
	var validation := SaveIOType._validate_state(state)
	_expect(validation["ok"], "a current-schema state with no constructionSites field must validate: %s" % validation.get("message", ""))
	if not validation["ok"]:
		return
	var world := StateCodecType.decode(state)
	_expect(world.get_construction_sites().is_empty(), "decode() must restore no construction sites when the field is absent")

## Acceptance: "a save mid-construction (partial materials, partial progress,
## one builder) round-trips with hash equality" -- exercised end-to-end in
## test_construction_site.gd; this proves the persisted wire shape itself
## (one record under "constructionSites", not one per footprint tile, mirroring
## "objects"'s own origin-record convention) survives SaveIO's own schema
## validator, not only StateCodec's internal round trip.
func _check_construction_site_round_trips_through_save_load() -> void:
	var world := WorldStateType.new(20260927, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._objects.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "route": null, "work": null, "carrying": null})
	var apply_result := world.apply({"actor": "test", "command_id": "wb", "tick": world.get_tick(), "type": "build",
		"payload": {"kind": "workbench", "x": 5, "y": 5}})
	_expect(bool(apply_result.get("ok", false)), "the setup build command must be accepted: %s" % apply_result)
	_expect(not world.get_construction_site(5, 5).is_empty(), "setup must create a real site before the round trip")
	var before_hash := world.state_hash()
	var saved := world.to_save_state()
	var sites: Array = saved.get("constructionSites", [])
	_expect(sites.size() == 1, "a single active site must persist as exactly one constructionSites record")
	var validation := SaveIOType._validate_state(saved)
	_expect(validation["ok"], "a state with an in-progress construction site must validate: %s" % validation.get("message", ""))
	var restored := WorldStateType.from_save_state(saved)
	_expect(restored.state_hash() == before_hash, "a construction-site save/load round trip must preserve state_hash() exactly")
	_expect(not restored.get_construction_site(5, 5).is_empty(), "the restored world must still show the site")

## Round 1 review regression (#349): a v21 fixture whose entity["needs"] is
## null must be rejected by _is_schema_v21_state() before
## _migrate_v21_to_v22() dereferences it as a Dictionary, not crash. Mutates
## the real v21 fixture rather than hand-building a second minimal state, so
## every other v21-required field stays genuinely valid.
func _check_malformed_v21_null_needs_is_rejected() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = null
	var result := SaveMigrationsType.migrate(state, 21, 22)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v21 null needs must be rejected, not crash: %s" % result)

## Same as _check_malformed_v21_null_needs_is_rejected() above but for an
## Array needs value, the other non-Dictionary JSON shape .keys() cannot be
## called on.
func _check_malformed_v21_array_needs_is_rejected() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = [1, 2, 3]
	var result := SaveMigrationsType.migrate(state, 21, 22)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v21 array needs must be rejected, not crash: %s" % result)

## Same as _check_malformed_v21_null_needs_is_rejected() above but for a
## scalar needs value.
func _check_malformed_v21_scalar_needs_is_rejected() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = 5
	var result := SaveMigrationsType.migrate(state, 21, 22)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v21 scalar needs must be rejected, not crash: %s" % result)

## Proves the null-needs rejection above is not just an in-memory
## SaveMigrations.migrate() check but holds for a real integrity-valid save
## file: SaveIO.read() must independently verify the envelope's hash, then
## still reject the malformed needs during migration, returning a typed
## failure rather than propagating a script error or returning partial state.
func _check_malformed_v21_null_needs_rejected_through_save_io() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = null
	var path := _write_state_fixture(V21_NEEDS_NULL_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(V21_NEEDS_NULL_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"an integrity-valid save with malformed v21 null needs must be rejected through SaveIO.read(), not crash: %s" % result)

## Same as _check_malformed_v21_null_needs_rejected_through_save_io() above
## but for an Array needs value.
func _check_malformed_v21_array_needs_rejected_through_save_io() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = [1, 2, 3]
	var path := _write_state_fixture(V21_NEEDS_ARRAY_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(V21_NEEDS_ARRAY_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"an integrity-valid save with malformed v21 array needs must be rejected through SaveIO.read(), not crash: %s" % result)

## Same as _check_malformed_v21_null_needs_rejected_through_save_io() above
## but for a scalar needs value.
func _check_malformed_v21_scalar_needs_rejected_through_save_io() -> void:
	var state := _load_fixture_state(_v21_fixture_path)
	(state["entities"][0] as Dictionary)["needs"] = 5
	var path := _write_state_fixture(V21_NEEDS_SCALAR_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(V21_NEEDS_SCALAR_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"an integrity-valid save with malformed v21 scalar needs must be rejected through SaveIO.read(), not crash: %s" % result)

## Round 2 review regression: _migrate_v20_to_v21() converts state["tick"] with
## int() to derive incidentScheduler.lastProcessedDay. Before this fix,
## _is_schema_v20_state() checked that "tick" was present but never its type,
## so an otherwise-valid v20 save with a Dictionary "tick" reached that int()
## call and threw a script error instead of a typed no_migration_available
## rejection. Mutates the real v20 fixture rather than hand-building a second
## minimal state, so every other v20-required field stays genuinely valid.
func _check_malformed_v20_dictionary_tick_is_rejected() -> void:
	var state := _load_fixture_state(FIXTURE_V20)
	state["tick"] = {"not": "an int"}
	var result := SaveMigrationsType.migrate(state, 20, 21)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v20 Dictionary tick must be rejected, not crash: %s" % result)

## Same as _check_malformed_v20_dictionary_tick_is_rejected() above but for an
## Array "tick", the other non-scalar JSON shape int() cannot coerce.
func _check_malformed_v20_array_tick_is_rejected() -> void:
	var state := _load_fixture_state(FIXTURE_V20)
	state["tick"] = [1, 2, 3]
	var result := SaveMigrationsType.migrate(state, 20, 21)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v20 Array tick must be rejected, not crash: %s" % result)

## Proves the Array-tick rejection above is not just an in-memory
## SaveMigrations.migrate() check but holds for a real integrity-valid save
## file: SaveIO.read() must independently verify the envelope's hash, then
## still reject the malformed tick during migration, returning a typed
## failure rather than propagating a script error or returning partial state.
func _check_malformed_v20_tick_rejected_through_save_io() -> void:
	var state := _load_fixture_state(FIXTURE_V20)
	state["tick"] = [1, 2, 3]
	var path := _write_state_fixture(V20_TICK_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(V20_TICK_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"an integrity-valid save with a malformed v20 tick must be rejected through SaveIO.read(), not crash: %s" % result)
	_expect(not result.has("state"),
		"a rejected malformed-tick save must not return partial state: %s" % result)

## #295: proves the incident scheduler's own continuation state -- non-empty
## per-incident cooldowns, a non-zero last-processed day, and a
## non-freshly-seeded RNG stream (distinct seed and state from a brand-new
## IncidentScheduler's own construction-time values) -- survives a real
## WorldState.to_save_state() -> StateCodec.encode() -> from_save_state() ->
## StateCodec.decode() round trip exactly, covering
## _encode_incident_scheduler()/decode()'s restore end to end, the same way
## _check_non_default_labour_table_survives_save_load_round_trip() proves it
## for the labour table.
func _check_incident_scheduler_continuation_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260924, 10)
	world._incidents._cooldown_until_day = {"wildlife_wander": 12, "trader_visit": 19}
	world._incidents._last_processed_day = 7
	world._incidents._random.seed = 555
	world._incidents._random.randi() # advances .state away from its fresh-seed default
	var expected_cooldowns: Dictionary = world._incidents._cooldown_until_day.duplicate()
	var expected_day: int = world._incidents._last_processed_day
	var expected_rng_seed: int = world._incidents._random.seed
	var expected_rng_state: int = world._incidents._random.state

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	_expect(restored._incidents._cooldown_until_day == expected_cooldowns,
		"a save/load round trip must preserve the incident scheduler's cooldownUntilDay exactly")
	_expect(restored._incidents._last_processed_day == expected_day,
		"a save/load round trip must preserve the incident scheduler's lastProcessedDay exactly")
	_expect(restored._incidents._random.seed == expected_rng_seed and restored._incidents._random.state == expected_rng_state,
		"a save/load round trip must preserve the incident scheduler's own RNG stream exactly")

## #257: SaveIO.read() must reject a save whose stored contentVersion does not
## match the content bundle currently on disk (StateCodec.content_version())
## with the new typed content_version_mismatch code when no content-rename
## entry resolves it -- never silently proceeding with a stale content id.
func _check_content_version_mismatch_without_rename_fails() -> void:
	var current_content_version := StateCodecType.content_version()
	var state := _minimal_current_schema_state("definitely-not-" + current_content_version, "wood")
	var path := _write_state_fixture(CONTENT_MISMATCH_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_expect(not result["ok"] and result["code"] == "content_version_mismatch",
		"a save whose contentVersion has no registered rename must fail with content_version_mismatch: %s" % result)
	_cleanup_dir(CONTENT_MISMATCH_FIXTURE_DIR)

## #257: proves the content-rename hook actually runs, not just the mismatch
## check itself: a save's contentVersion resolved by a registered rename must
## load successfully, and the rename's own id remap (here, an item's "kind")
## must have taken effect in the state SaveIO.read() hands back.
func _check_content_version_mismatch_resolved_by_rename_loads() -> void:
	var current_content_version := StateCodecType.content_version()
	_expect(current_content_version != RENAME_SOURCE_CONTENT_VERSION,
		"test fixture content version must actually differ from the current registry version")
	var state := _minimal_current_schema_state(RENAME_SOURCE_CONTENT_VERSION, "legacy_wood")
	var path := _write_state_fixture(CONTENT_RENAME_FIXTURE_DIR, state)
	SaveMigrationsType.register_content_rename(RENAME_SOURCE_CONTENT_VERSION, Callable(self, "_rename_legacy_wood_item_kind"))
	var result := SaveIOType.read(path)
	SaveMigrationsType.unregister_content_rename(RENAME_SOURCE_CONTENT_VERSION)
	_expect(result["ok"], "a save whose contentVersion is resolved by a registered rename must load: %s" % result)
	_cleanup_dir(CONTENT_RENAME_FIXTURE_DIR)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect(String(loaded_state["contentVersion"]) == current_content_version,
		"a resolved save must report the current content version after load")
	var loaded_kind := String((loaded_state["items"]["list"] as Array)[0]["kind"])
	_expect(loaded_kind == "wood",
		"the registered rename must actually remap the renamed content id, not just flip the version: got '%s'" % loaded_kind)

## Issue #449: content/objects.json's "wall" row was replaced by "wooden_wall"
## (unchanged build_cost) and a new "stone_wall" row. Proves the real,
## non-test-only content-rename entry SaveMigrations registers for itself
## (WALL_RENAME_FROM_CONTENT_VERSION, the checkout's own contentVersion before
## this rename) actually resolves a pre-task save through SaveIO.read() --
## never a test-registered stand-in like the check above -- so a save written
## before this task, carrying an object of kind "wall", loads with that
## object now reporting "wooden_wall".
func _check_wall_content_rename_migrates_to_wooden_wall() -> void:
	var current_content_version := StateCodecType.content_version()
	_expect(current_content_version != SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION,
		"the current content bundle must have moved on from the pre-rename contentVersion")
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": "wall", "factionId": "colony"}]
	var path := _write_state_fixture(WALL_RENAME_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_FIXTURE_DIR)
	_expect(result["ok"], "a pre-task save with a 'wall' object must load through SaveIO.read() via the production content-rename hook: %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect(String(loaded_state["contentVersion"]) == current_content_version,
		"a resolved save must report the current content version after load")
	var objects: Array = loaded_state["objects"]
	_expect(objects.size() == 1, "the renamed object must survive the load")
	if objects.size() == 1:
		_expect(String((objects[0] as Dictionary)["kind"]) == "wooden_wall",
			"a pre-task 'wall' object must be renamed to 'wooden_wall' by the production content-rename hook")
	var world := StateCodecType.decode(loaded_state)
	_expect(world.get_object(0, 0) == "wooden_wall", "the decoded world must expose the renamed object as 'wooden_wall'")

## Round 2 review (issue #449): the check above only proves a COMPLETED "wall"
## object is renamed. A pre-task save can just as easily carry an UNFINISHED
## "wall" construction site (ADR 038's own persistent site model) -- this
## proves the production content-rename hook also renames a
## constructionSites[].kind entry, preserves that site's own persisted
## requiredMaterials/buildTicks exactly (never recomputed from current
## content: those are the site's own truthful history, not a content id), and
## that the renamed site can still be delivered to and completed after load,
## with the completed object correctly impassable and carrying content's own
## current health.
func _check_pretask_wall_construction_site_continues_as_wooden_wall_after_load() -> void:
	var world := WorldStateType.new(449001, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._colonists.clear()
	world._objects.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100}, "route": null, "work": null, "carrying": null})
	var zone_result := world.apply({"actor": "test", "command_id": "zone", "tick": world.get_tick(),
		"type": "zone_add", "payload": {"x": 0, "y": 0, "width": 1, "height": 1}})
	_expect(zone_result.get("ok", false), "setup: zone_add must be accepted: %s" % zone_result)
	world._items["item_1"] = {"id": "item_1", "x": 0, "y": 0, "kind": "wood", "count": 1}
	world._next_item_id = 2
	var build_result := world.apply({"actor": "test", "command_id": "door_1", "tick": world.get_tick(),
		"type": "build", "payload": {"kind": "door", "x": 5, "y": 5}})
	_expect(build_result.get("ok", false), "setup: build must be accepted: %s" % build_result)

	var saved := world.to_save_state()
	var sites: Array = (saved.get("constructionSites", []) as Array).duplicate(true)
	_expect(sites.size() == 1, "setup: exactly one construction site must exist before relabeling")
	if sites.size() != 1:
		return
	var site: Dictionary = (sites[0] as Dictionary).duplicate(true)
	# Relabel this real site as if it had been ordered as a "wall" before this
	# task's rename: its own persisted requiredMaterials/buildTicks reflect
	# whatever "wall" declared at the time it was ordered (build_cost 1 wood,
	# 40 build_ticks -- distinct from wooden_wall's own 20, so preservation
	# through the rename is provable), not the current content's shape.
	site["kind"] = "wall"
	site["requiredMaterials"] = [{"item": "wood", "quantity": 1}]
	site["buildTicks"] = 40
	saved["constructionSites"] = [site]
	saved["contentVersion"] = SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION

	var path := _write_state_fixture(WALL_SITE_RENAME_FIXTURE_DIR, saved)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_SITE_RENAME_FIXTURE_DIR)
	_expect(result.get("ok", false), "a pre-task save with a 'wall' construction site must load via the production content-rename hook: %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	var loaded_sites: Array = loaded_state.get("constructionSites", [])
	_expect(loaded_sites.size() == 1, "the renamed site must survive the load")
	if loaded_sites.size() != 1:
		return
	var loaded_site: Dictionary = loaded_sites[0]
	_expect(String(loaded_site["kind"]) == "wooden_wall",
		"a pre-task 'wall' construction site must be renamed to 'wooden_wall' by the production content-rename hook")
	_expect(int(loaded_site["buildTicks"]) == 40,
		"the content-rename must preserve the site's own persisted buildTicks exactly, not recompute it from current content")
	_expect(loaded_site["requiredMaterials"] == [{"item": "wood", "quantity": 1}],
		"the content-rename must preserve the site's own persisted requiredMaterials exactly")

	var restored := StateCodecType.decode(loaded_state)
	_expect(not restored.get_construction_site(5, 5).is_empty(), "the decoded world must still carry the renamed site")

	var completed := false
	for _i in 400:
		restored.tick()
		if not restored.get_object(5, 5).is_empty():
			completed = true
			break
	_expect(completed, "the renamed site must still be able to receive its held material and complete construction after load")
	if not completed:
		return
	_expect(restored.get_object(5, 5) == "wooden_wall", "the completed object must report the renamed kind 'wooden_wall'")
	_expect(not (restored.passability(5, 5)["passable"] as bool), "a completed wooden_wall must be impassable, matching content's own passable:false")
	var registry := ContentRegistryType.new()
	var wooden_wall_definition := registry.get_entry("objects", "wooden_wall")
	var health: Dictionary = restored._object_health_at(5, 5)
	_expect(not health.is_empty(), "a completed wooden_wall must carry per-instance health")
	_expect(int(health.get("maxHp", -1)) == int(wooden_wall_definition.get("max_health", -2)),
		"the completed wooden_wall's maxHp must come from content's own current max_health")

## Round 2 review (issue #449): a pre-task save can carry a queued/active
## legacy (pre-#406) "build" job whose own retired buildKind is "wall" just as
## easily as a completed object or an ADR-038 site. Before this fix, SaveIO
## ran SaveMigrations.migrate_legacy_build_jobs() BEFORE resolving the content
## rename, so this buildKind was looked up directly against the CURRENT
## content bundle -- which no longer has "wall" -- and registry.get_entry()'s
## own empty-dictionary-on-miss fallback silently synthesized a site with an
## empty requiredMaterials and buildTicks 1. Proves the fixed ordering
## (content-rename resolved first) carries the pre-#449 buildKind through the
## rename before that lookup, so the synthesized site matches wooden_wall's
## real, current content -- read live off ContentRegistry, never hand-typed
## (docs L-013), so this stays correct if wooden_wall's own cost ever changes.
func _check_legacy_wall_build_job_synthesizes_wooden_wall_site_via_content_rename() -> void:
	var current_content_version := StateCodecType.content_version()
	_expect(current_content_version != SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION,
		"the current content bundle must have moved on from the pre-rename contentVersion")
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["jobs"] = [{
		"id": "job_1", "kind": "build", "status": "queued", "priority": 1,
		"target": {"x": 0, "y": 0}, "reason": "", "remedy": "", "blockingJobId": "",
		"itemId": "item_1", "cell": null, "retryAt": 0, "backoffTicks": 0,
		"site": {"x": 0, "y": 0}, "buildKind": "wall",
	}]
	state["scheduling"]["nextJobId"] = 2

	var path := _write_state_fixture(LEGACY_WALL_BUILD_JOB_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(LEGACY_WALL_BUILD_JOB_FIXTURE_DIR)
	_expect(result["ok"], "a pre-#449 save with a legacy 'wall' build job must still load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect(String(loaded_state["contentVersion"]) == current_content_version,
		"a resolved save must report the current content version after load")
	var jobs: Array = loaded_state["jobs"]
	_expect(jobs.size() == 1, "the legacy job must survive the load")
	if jobs.size() != 1:
		return
	var job: Dictionary = jobs[0]
	_expect(String(job["kind"]) == "site_fetch", "a legacy 'build' job must migrate to 'site_fetch'")
	_expect(not job.has("buildKind"), "a migrated job must not carry the retired buildKind field")
	var sites: Array = loaded_state.get("constructionSites", [])
	_expect(sites.size() == 1, "a construction site must be synthesized for the legacy job's own site tile")
	if sites.size() != 1:
		return
	var site: Dictionary = sites[0]
	_expect(String(site["kind"]) == "wooden_wall",
		"the synthesized site's own kind must be resolved through the content-rename before the registry lookup, not left as the retired 'wall' id")
	var registry := ContentRegistryType.new()
	var wooden_wall_definition := registry.get_entry("objects", "wooden_wall")
	_expect(site["requiredMaterials"] == (wooden_wall_definition.get("build_cost", []) as Array),
		"the synthesized site's requiredMaterials must come from wooden_wall's real, current build_cost, not an empty registry-miss fallback")
	_expect(int(site["buildTicks"]) == int(wooden_wall_definition.get("build_ticks", -1)),
		"the synthesized site's buildTicks must come from wooden_wall's real, current build_ticks, not the registry.get_entry() empty-dictionary fallback of 1")

	var world := StateCodecType.decode(loaded_state)
	_expect(world.get_construction_sites().size() == 1, "the decoded world must carry the synthesized wooden_wall site")

## Round 2 review (issue #449): a save entering the content-rename path
## (contentVersion == WALL_RENAME_FROM_CONTENT_VERSION) with no "objects"
## field at all must still be rejected as missing that required field --
## before the fix, _rename_wall_to_wooden_wall() fabricated an empty array
## for an absent "objects", which made this otherwise-valid-shaped save look
## structurally complete and silently pass validation.
func _check_wall_rename_missing_objects_field_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state.erase("objects")
	var path := _write_state_fixture(WALL_RENAME_MISSING_OBJECTS_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_MISSING_OBJECTS_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"a wall-rename-path save missing 'objects' must be rejected as a missing required field, not fabricated into an empty one: %s" % result)

## Same as _check_wall_rename_missing_objects_field_rejected_through_save_io()
## above but for the absent "jobs" field.
func _check_wall_rename_missing_jobs_field_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state.erase("jobs")
	var path := _write_state_fixture(WALL_RENAME_MISSING_JOBS_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_MISSING_JOBS_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"a wall-rename-path save missing 'jobs' must be rejected as a missing required field, not fabricated into an empty one: %s" % result)

## Round 2 review (issue #449): a save missing "contentVersion" entirely must
## be rejected as a missing required field, not coerced through String() into
## an empty-string content id and misreported as a content_version_mismatch.
func _check_wall_rename_missing_content_version_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state.erase("contentVersion")
	var path := _write_state_fixture(WALL_RENAME_MISSING_CONTENT_VERSION_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_MISSING_CONTENT_VERSION_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"a save missing 'contentVersion' must be rejected as a missing required field, not as a content_version_mismatch: %s" % result)

## Round 2 review (issue #449): a non-String "contentVersion" (e.g. a number)
## must be rejected with the schema's own "invalid contentVersion" error, not
## silently coerced through String() first and misreported as a
## content_version_mismatch.
func _check_wall_rename_invalid_content_version_type_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["contentVersion"] = 10
	var path := _write_state_fixture(WALL_RENAME_INVALID_CONTENT_VERSION_TYPE_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_CONTENT_VERSION_TYPE_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a save with a non-String contentVersion must be rejected with a schema_error, not misreported as content_version_mismatch: %s" % result)

## Round 2 review (issue #449): "objects" carrying the wrong type (not an
## Array) on a save entering the content-rename path must be rejected by
## _validate_state()'s own "invalid objects type" check, not crash inside
## _rename_wall_to_wooden_wall()'s former unconditional `as Array` cast.
func _check_wall_rename_invalid_objects_container_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["objects"] = "not-an-array"
	var path := _write_state_fixture(WALL_RENAME_INVALID_OBJECTS_CONTAINER_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_OBJECTS_CONTAINER_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Array 'objects' must be rejected with a schema_error, not crash: %s" % result)

## Same as _check_wall_rename_invalid_objects_container_rejected_through_save_io()
## above but for a well-typed Array "objects" whose own entry is not a
## Dictionary -- must be rejected by _valid_object()'s own "invalid objects
## entry type" check, not crash inside the former unconditional
## `(object_value as Dictionary).duplicate(true)` cast.
func _check_wall_rename_invalid_objects_entry_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["objects"] = ["not-a-dictionary"]
	var path := _write_state_fixture(WALL_RENAME_INVALID_OBJECTS_ENTRY_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_OBJECTS_ENTRY_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Dictionary objects entry must be rejected with a schema_error, not crash: %s" % result)

## Same as the objects-container check above but for "constructionSites".
func _check_wall_rename_invalid_construction_sites_container_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["constructionSites"] = "not-an-array"
	var path := _write_state_fixture(WALL_RENAME_INVALID_SITES_CONTAINER_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_SITES_CONTAINER_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Array 'constructionSites' must be rejected with a schema_error, not crash: %s" % result)

## Same as the objects-entry check above but for "constructionSites".
func _check_wall_rename_invalid_construction_sites_entry_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["constructionSites"] = ["not-a-dictionary"]
	var path := _write_state_fixture(WALL_RENAME_INVALID_SITES_ENTRY_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_SITES_ENTRY_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Dictionary constructionSites entry must be rejected with a schema_error, not crash: %s" % result)

## Same as the objects-container check above but for "jobs".
func _check_wall_rename_invalid_jobs_container_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["jobs"] = "not-an-array"
	var path := _write_state_fixture(WALL_RENAME_INVALID_JOBS_CONTAINER_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_JOBS_CONTAINER_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Array 'jobs' must be rejected with a schema_error, not crash: %s" % result)

## Same as the objects-entry check above but for "jobs".
func _check_wall_rename_invalid_jobs_entry_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["jobs"] = ["not-a-dictionary"]
	var path := _write_state_fixture(WALL_RENAME_INVALID_JOBS_ENTRY_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_INVALID_JOBS_ENTRY_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-Dictionary jobs entry must be rejected with a schema_error, not crash: %s" % result)

## Round 4 review (issue #449): a well-typed Dictionary objects entry whose own
## "kind" field is not a String (an integrity-valid old-content save could
## carry a numeric, Array, Dictionary, or null value there) must not reach
## _rename_wall_to_wooden_wall()'s former unconditional String() cast, which
## the reviewer found raises a script error for those types. The field must
## instead pass through untouched so _matches_id_pattern() rejects it with the
## same "invalid objects entry" schema_error a non-String kind already gets on
## any other content version.
func _check_wall_rename_non_string_object_kind_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["objects"] = [{"target": {"x": 0, "y": 0}, "kind": 123, "factionId": "colony"}]
	var path := _write_state_fixture(WALL_RENAME_NON_STRING_OBJECT_KIND_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_NON_STRING_OBJECT_KIND_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-String objects[].kind must be rejected with a schema_error, not crash: %s" % result)

## Same as _check_wall_rename_non_string_object_kind_rejected_through_save_io()
## above but for constructionSites[].kind.
func _check_wall_rename_non_string_construction_site_kind_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["constructionSites"] = [{
		"id": "site_1", "kind": 123, "origin": {"x": 0, "y": 0}, "orientation": "",
		"requiredMaterials": [], "heldMaterials": [], "progress": 0, "buildTicks": 1,
		"maxBuilders": 1, "builderIds": [],
	}]
	var path := _write_state_fixture(WALL_RENAME_NON_STRING_SITE_KIND_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_NON_STRING_SITE_KIND_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-String constructionSites[].kind must be rejected with a schema_error, not crash: %s" % result)

## Same as the two checks above but for jobs[].buildKind -- uses a "dig" job
## (a currently-valid, non-"build" kind) rather than a legacy "build" job so
## this exercises only _rename_wall_to_wooden_wall()'s own field-type guard,
## never SaveMigrations.migrate_legacy_build_jobs() (which only ever looks at
## buildKind on a job whose kind is still "build").
func _check_wall_rename_non_string_job_build_kind_rejected_through_save_io() -> void:
	var state := _minimal_current_schema_state(SaveMigrationsType.WALL_RENAME_FROM_CONTENT_VERSION, "wood")
	state["jobs"] = [{
		"id": "job_1", "kind": "dig", "status": "queued", "priority": 1,
		"target": {"x": 0, "y": 0}, "reason": "", "remedy": "", "blockingJobId": "",
		"itemId": "", "cell": null, "retryAt": 0, "backoffTicks": 0,
		"buildKind": 123,
	}]
	var path := _write_state_fixture(WALL_RENAME_NON_STRING_JOB_BUILD_KIND_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(WALL_RENAME_NON_STRING_JOB_BUILD_KIND_FIXTURE_DIR)
	_expect(not result["ok"] and result["code"] == "schema_error",
		"a wall-rename-path save with a non-String jobs[].buildKind must be rejected with a schema_error, not crash: %s" % result)

## Round 2 review regression: a real calendar window id is allowed to be any
## non-empty string (game/content/schemas/calendar.schema.json), so a window
## named "SpringSow" -- mixed case, no underscore/hyphen -- must still round
## trip through a full save file, not just satisfy an in-memory Dictionary
## check. Before this fix, SaveIO's stricter ^[a-z0-9_-]+$ id pattern rejected
## it, so a colony that legitimately fired that window's alert could never
## save again.
func _check_calendar_alerts_fired_accepts_valid_non_lowercase_id() -> void:
	var window_id := "SpringSow"
	var state := _minimal_current_schema_state(StateCodecType.content_version(), "wood")
	state["calendarAlerts"] = {"fired": [window_id]}
	var validation := SaveIOType._validate_state(state)
	_expect(validation["ok"], "a valid non-lowercase calendar id must pass _validate_state: %s" % validation.get("message", ""))

	var path := _write_state_fixture(CALENDAR_ID_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(CALENDAR_ID_FIXTURE_DIR)
	_expect(result["ok"], "a save with a valid non-lowercase calendar id must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	_expect((loaded_state["calendarAlerts"]["fired"] as Array) == [window_id],
		"SaveIO.read() must preserve the calendar id '%s' exactly, got %s" % [window_id, loaded_state["calendarAlerts"]])

## Round-4 review: a save written before construction sites existed (issue
## #406) can still carry a legacy "build" job (JobQueue.BUILD_KIND, the
## single-worker fetch-then-work job this task's own site-based model
## replaced) even though schemaVersion never moved -- the new "site_fetch"/
## "site_work" kinds and constructionSites only widened v25's existing wire
## shape (the same additive-compatibility precedent objects[].orientation and
## constructionSites' own absence already established above), so a save
## carrying one must still load rather than fail with "invalid job kind".
## SaveMigrations.migrate_legacy_build_jobs() converts it into a fresh site
## and a "site_fetch" job pointed at it (there is truthfully nothing to
## resume from a legacy build job's own progress -- see that function's own
## doc comment), which ConstructionGiver then re-derives real fetch/work jobs
## for on its very next tick. Uses "door" (a stable, currently-valid content
## id, not "wall") so this generic legacy-job-synthesis mechanism keeps being
## exercised independently of any one content id's own rename history -- see
## _check_legacy_wall_build_job_synthesizes_wooden_wall_site_via_content_rename()
## for the "wall"-specific content-rename-ordering regression. Round 2 review:
## also proves the synthesized site's own requiredMaterials/buildTicks/
## maxBuilders actually come from the buildKind's real, current content
## definition -- read live off ContentRegistry, never hand-typed (docs
## L-013) -- not just that a site of some shape exists.
func _check_legacy_build_job_loads_through_save_io() -> void:
	var state := _minimal_current_schema_state(StateCodecType.content_version(), "wood")
	state["jobs"] = [{
		"id": "job_1", "kind": "build", "status": "queued", "priority": 1,
		"target": {"x": 0, "y": 0}, "reason": "", "remedy": "", "blockingJobId": "",
		"itemId": "item_1", "cell": null, "retryAt": 0, "backoffTicks": 0,
		"site": {"x": 0, "y": 0}, "buildKind": "door",
	}]
	state["scheduling"]["nextJobId"] = 2

	var path := _write_state_fixture(LEGACY_BUILD_JOB_FIXTURE_DIR, state)
	var result := SaveIOType.read(path)
	_cleanup_dir(LEGACY_BUILD_JOB_FIXTURE_DIR)
	_expect(result["ok"], "a save with a legacy 'build' job must still load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var loaded_state: Dictionary = result["state"]
	var jobs: Array = loaded_state["jobs"]
	_expect(jobs.size() == 1, "the legacy job must survive the load")
	if jobs.size() != 1:
		return
	var job: Dictionary = jobs[0]
	_expect(String(job["kind"]) == "site_fetch", "a legacy 'build' job must migrate to 'site_fetch'")
	_expect(not job.has("buildKind"), "a migrated job must not carry the retired buildKind field")
	var sites: Array = loaded_state.get("constructionSites", [])
	_expect(sites.size() == 1, "a construction site must be synthesized for the legacy job's own site tile")
	if sites.size() == 1:
		var site: Dictionary = sites[0]
		_expect(String(site["kind"]) == "door", "the synthesized site must carry the legacy job's own buildKind")
		_expect(site["origin"] == {"x": 0, "y": 0}, "the synthesized site must sit at the legacy job's own site tile")
		_expect((site["heldMaterials"] as Array).is_empty(), "a synthesized site has truthfully nothing already delivered")
		_expect(int(site["progress"]) == 0, "a synthesized site has truthfully no progress yet")
		var registry := ContentRegistryType.new()
		var door_definition := registry.get_entry("objects", "door")
		_expect(site["requiredMaterials"] == (door_definition.get("build_cost", []) as Array),
			"the synthesized site's requiredMaterials must come from the buildKind's real, current build_cost")
		_expect(int(site["buildTicks"]) == int(door_definition.get("build_ticks", -1)),
			"the synthesized site's buildTicks must come from the buildKind's real, current build_ticks")
		_expect(int(site["maxBuilders"]) == int(door_definition.get("max_builders", -1)),
			"the synthesized site's maxBuilders must come from the buildKind's real, current max_builders")

	var world := StateCodecType.decode(loaded_state)
	_expect(world.get_construction_sites().size() == 1, "the decoded world must carry the synthesized construction site")

## A minimal but fully current-schema-shaped state (empty entities/jobs/etc.,
## _validate_state has no minimum-count requirement on any collection) with
## one ground item, used by the content-version mismatch checks above: only
## contentVersion and the one item's "kind" vary between calls.
func _minimal_current_schema_state(content_version: String, item_kind: String) -> Dictionary:
	return {
		"schemaVersion": SaveIOType.SCHEMA_VERSION, "contentVersion": content_version, "seed": 1, "tick": 0,
		"epoch": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"], "generatorVersion": 1},
		"entities": [],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {}, "activatedEntries": {},
		},
		"rng": {"seed": 1, "state": 0},
		"items": {"nextId": 2, "list": [{"id": "item_1", "x": 0, "y": 0, "kind": item_kind, "count": 1, "factionId": "colony"}]},
		"objects": [], "zones": [], "nextZoneId": 1, "groundBerries": [],
		"workProgress": [], "pausedJobs": [], "toolItems": {"nextId": 1, "list": []},
		"toolReservations": {}, "needJobAssignments": [], "calendarAlerts": {"fired": []},
		"toolFetchExcluded": [],
		"incidentScheduler": {"cooldownUntilDay": {}, "lastProcessedDay": 1, "rng": {"seed": 1, "state": 0}},
	}

## Test-registered content-rename remap (see
## _check_content_version_mismatch_resolved_by_rename_loads()): renames every
## "legacy_wood" item kind to "wood", proving the hook remaps content ids
## inside the loaded state rather than just relabeling contentVersion.
func _rename_legacy_wood_item_kind(state: Dictionary) -> Dictionary:
	var remapped: Dictionary = state.duplicate(true)
	var items: Dictionary = (remapped["items"] as Dictionary).duplicate(true)
	var list: Array = []
	for entry in (items["list"] as Array):
		var updated: Dictionary = (entry as Dictionary).duplicate(true)
		if String(updated["kind"]) == "legacy_wood":
			updated["kind"] = "wood"
		list.append(updated)
	items["list"] = list
	remapped["items"] = items
	return remapped

## #241 review round 2: proves NeedGiver's own colonist_id -> job_id
## association and the interrupted dig job's requeued scheduler entry both
## survive a real save/load round trip -- not just a migration-shaped
## dictionary, WorldState.to_save_state()/from_save_state() end to end -- so
## a need job that was already committed at save time can still resolve_job()
## its way back to the paused colonist and resume the original work job with
## its tile progress kept, not lost or restarted, after loading.
func _check_critical_interrupt_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(130001, 10)
	for other in world._need_definitions.keys():
		if other != "food":
			world._need_definitions[other]["rate_per_day"] = 0
	world._colonists.clear()
	world._colonists.append({
		"id": "colonist_0", "kind": "colonist", "x": 9, "y": 0,
		"needs": {"food": 100, "water": 100, "rest": 100},
		"labourTable": world._default_labour_table(),
		"route": null, "work": null, "hands": [],
	})
	world._tiles[world._tile_index(10, 0)] = WorldStateType.TILE_SOIL
	# Far enough that the eat_food search/walk spans several ticks, so the
	# save captures a genuinely still-pending need job rather than one that
	# already committed, walked, ate, and resumed the dig job all within the
	# same tick the critical interrupt fired.
	world._ground_berries["9_20"] = 1
	world.spawn_ground_tool_item("pick", 9, 0)

	var dig_result := world.apply({
		"actor": "test", "command_id": "dig_1", "tick": world.get_tick(),
		"type": "dig", "payload": {"x": 10, "y": 0, "priority": 1},
	})
	_expect(dig_result["ok"], "the dig order must be accepted")
	var dig_job_id := String(dig_result.get("job_id", ""))

	var work_started := false
	for _i in 30:
		world.tick()
		for colonist in world.get_colonists():
			if colonist["id"] == "colonist_0" and colonist.get("work") != null:
				work_started = true
		if work_started:
			break
	_expect(work_started, "colonist_0 must start the dig job's work toil within the tick budget")
	if not work_started:
		return
	for _i in 5:
		world.tick()

	for i in world._colonists.size():
		if String(world._colonists[i]["id"]) == "colonist_0":
			world._colonists[i]["needs"]["food"] = 5
	world.tick()

	# Tick until the eat_food job is actually committed (not just searching),
	# so the save captures NeedGiver's own persisted association in use, not
	# just an in-flight search this task's own non-goal already excludes from
	# persistence.
	var committed := false
	for _i in 60:
		if not world._need_giver.get_pending_assignments().is_empty():
			committed = true
			break
		world.tick()
	_expect(committed, "colonist_0's need search must commit to a job within the tick budget")
	if not committed:
		return

	var saved := world.to_save_state()
	_expect((saved["needJobAssignments"] as Array).size() == 1,
		"a save taken while a need job is pending must persist NeedGiver's own colonist->job association")
	_expect((saved["pausedJobs"] as Array).size() == 1,
		"a save taken mid-interrupt must persist the paused dig job")
	# Round-6 review (#278/#303): a suspended job's own progress persists via
	# job-id-keyed "suspendedWorkProgress", not the shared tile-keyed
	# "workProgress" array -- world_state.gd's own _suspend_work_progress()
	# moves it out the instant the interrupt clears colonist.work.
	var suspended_work_progress: Array = saved["suspendedWorkProgress"]
	var dig_target_progress := int(suspended_work_progress[0]["ticksRemaining"]) if suspended_work_progress.size() > 0 else -1
	_expect(dig_target_progress > 0 and dig_target_progress < int(world._work_ticks["dig"]),
		"a save taken mid-interrupt must persist the dig job's own partial progress")

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	# from_save_state() constructs a brand new WorldState, which reloads
	# _need_definitions fresh from content/needs.json: the water/rest rate=0
	# override above is test-only scaffolding (content, not persisted runtime
	# state), so it must be re-applied here too, or water/rest resume normal
	# decay post-load and trigger their own unrelated interrupts, diverging
	# this check from what it actually means to test.
	for other in restored._need_definitions.keys():
		if other != "food":
			restored._need_definitions[other]["rate_per_day"] = 0
	_expect(restored._need_giver.get_pending_assignments() == world._need_giver.get_pending_assignments(),
		"loading must restore NeedGiver's own colonist->job association exactly")

	var eat_completed := false
	var dig_completed := false
	var colonist_0_ever_fed := false
	for _i in 300:
		restored.tick()
		for job in restored.get_jobs():
			if String(job["kind"]) == "eat_food" and job["status"] == "completed":
				eat_completed = true
			if String(job["id"]) == dig_job_id and job["status"] == "completed":
				dig_completed = true
		for colonist in restored.get_colonists():
			if colonist["id"] == "colonist_0" and int(colonist.get("needs", {}).get("food", 0)) == 100:
				colonist_0_ever_fed = true
		if eat_completed and dig_completed:
			break

	_expect(eat_completed, "the eat_food job must complete after loading")
	_expect(dig_completed, "the interrupted dig job must resume (not be lost) and complete after loading")
	_expect(restored.get_tile(10, 0) == WorldStateType.TILE_TRENCH,
		"the resumed dig job must still finish transforming its target tile after loading")
	_expect(colonist_0_ever_fed,
		"the interrupted colonist's own food need must be restored at some point after loading")

## Proves a non-default labourTable (set via set_labour, per world_state.gd's
## _apply_set_labour_command()) survives a real save/load round trip exactly,
## not just a migration-shaped dictionary: WorldState.to_save_state() goes
## through StateCodec.encode() and from_save_state() through
## StateCodec.decode(), the same pair every other in-flight state check in
## test_save_determinism.gd exercises, covering _encode_labour_table()/
## _decode_labour_table() end to end.
func _check_non_default_labour_table_survives_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260919, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 2, "expected at least two colonists for this check")
	if colonists.size() < 2:
		return
	var target_id: String = colonists[0]["id"]
	var other_id: String = colonists[1]["id"]
	var result := world.apply({
		"actor": "player", "command_id": "labour_round_trip", "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": target_id, "kind": "mine", "level": 0},
	})
	_expect(result.get("ok", false), "set_labour setup must be accepted: %s" % result)
	var second := world.apply({
		"actor": "player", "command_id": "labour_round_trip_2", "tick": world.get_tick(),
		"type": "set_labour", "payload": {"colonist": target_id, "kind": "cook", "level": 4},
	})
	_expect(second.get("ok", false), "second set_labour setup must be accepted: %s" % second)

	var expected_target_table: Dictionary = {}
	for colonist in world.get_colonists():
		if colonist["id"] == target_id:
			expected_target_table = (colonist["labourTable"] as Dictionary).duplicate()
	_expect(expected_target_table == {"mine": 0, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 4},
		"setup must leave the target colonist's table non-default in exactly the expected shape")

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	for colonist in restored.get_colonists():
		if colonist["id"] == target_id:
			_expect(colonist["labourTable"] == expected_target_table,
				"a save/load round trip must preserve the targeted colonist's complete labourTable exactly")
		elif colonist["id"] == other_id:
			_expect(colonist["labourTable"] == world._default_labour_table(),
				"a save/load round trip must not disturb a different colonist's untouched labourTable")

## #353: the "mine" job kind and "stone" item kind are new content (rock
## outcrops mined like trees, issue #372); this proves a real WorldState
## save/load round trip carries an active mine job and a ground stone item
## through unchanged, mirroring the labour-table check above rather than the
## v13-v21 migration-backfill checks (there is truthfully nothing to backfill:
## an old save with no mine job or stone item must keep loading unchanged).
## colonist_0 is given a held "pick" tool up front so the submitted mine job
## reaches "active" status on its very first tick instead of first spending a
## tick on the fetch_tool toil (jobs.json's "mine" entry needs_tool: "pick").
func _check_mine_job_and_stone_item_survive_save_load_round_trip() -> void:
	var world := WorldStateType.new(353001, 10)
	world._tiles.fill(WorldStateType.TILE_FLOOR)
	world._tiles[world._tile_index(1, 0)] = WorldStateType.TILE_ROCK
	world._colonists.clear()
	world._colonists.append({"id": "colonist_0", "kind": "colonist", "x": 0, "y": 0,
		"route": null, "work": null, "hands": [], "labourTable": world._default_labour_table()})
	world.set_tool_item_held(world.spawn_ground_tool_item("pick", 0, 0), "colonist_0")

	var submit := world.apply({
		"actor": "test", "command_id": "mine_1", "tick": world.get_tick(),
		"type": "mine", "payload": {"x": 1, "y": 0, "priority": 1},
	})
	_expect(submit.get("ok", false), "mine submission must be accepted: %s" % submit)
	var job_id := String(submit.get("job_id", ""))

	var active := false
	for _i in 10:
		world.tick()
		for job in world.get_jobs():
			if String(job["id"]) == job_id and String(job["status"]) == "active":
				active = true
		if active:
			break
	_expect(active, "setup: the mine job must reach active status before saving")
	_expect(world.get_tile(1, 0) == WorldStateType.TILE_ROCK, "setup: the target tile must still be rock, not yet mined")

	world._spawn_stone_item(5, 5)
	var stone_item_id := ""
	for item in world.get_items():
		if String(item["kind"]) == "stone":
			stone_item_id = String(item["id"])
	_expect(not stone_item_id.is_empty(), "setup: a ground stone item must exist before saving")

	var saved := world.to_save_state()
	var validation := SaveIOType._validate_state(saved)
	_expect(validation.get("ok", false),
		"a save state holding an active mine job and a ground stone item must pass SaveIO._validate_state(), got %s" % validation.get("message", ""))

	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	var restored_job := {}
	for job in restored.get_jobs():
		if String(job["id"]) == job_id:
			restored_job = job
	_expect(String(restored_job.get("kind", "")) == "mine" and String(restored_job.get("status", "")) == "active",
		"a save/load round trip must preserve the active mine job's kind and status exactly, got %s" % restored_job)
	_expect(restored_job.get("target") == Vector2i(1, 0),
		"a save/load round trip must preserve the mine job's target tile exactly")

	var restored_stone := {}
	for item in restored.get_items():
		if String(item["id"]) == stone_item_id:
			restored_stone = item
	_expect(restored_stone.get("kind") == "stone" and int(restored_stone.get("x", -1)) == 5
			and int(restored_stone.get("y", -1)) == 5 and int(restored_stone.get("count", -1)) == 1,
		"a save/load round trip must preserve the ground stone item exactly, got %s" % restored_stone)

## #284 review round 3: the migration-backfill checks above
## (_check_v17_fixture_migrates_to_v18/_check_v17_fixture_loads_through_save_io)
## only prove the default "colony"/full-health values a pre-existing entity is
## backfilled with -- they would still pass even if StateCodec silently reset
## factionId/health to those same defaults on every encode/decode, since every
## test fixture and every live-spawned colonist already starts at exactly
## those defaults. This check proves the opposite direction: a real,
## non-default factionId and two non-default health snapshots (an injured one
## with a non-default maxHp, and a dead one) survive an actual
## WorldState.to_save_state() -> StateCodec.encode()/SaveIO round trip ->
## WorldState.from_save_state() -> StateCodec.decode() cycle exactly, proving
## _encode_entities()/_decode_entities() genuinely carry these fields rather
## than only ever writing/reading their defaults.
func _check_non_default_faction_and_health_survive_save_load_round_trip() -> void:
	var world := WorldStateType.new(20260920, 10)
	var colonists := world.get_colonists()
	_expect(colonists.size() >= 3, "expected at least three colonists for this check")
	if colonists.size() < 3:
		return
	var faction_id: String = colonists[0]["id"]
	var injured_id: String = colonists[1]["id"]
	var dead_id: String = colonists[2]["id"]

	var expected_faction := "raiders"
	var expected_injured_health := {"hp": 40, "maxHp": 150, "dead": false}
	var expected_dead_health := {"hp": 0, "maxHp": 80, "dead": true}
	for i in world._colonists.size():
		var id := String(world._colonists[i]["id"])
		if id == faction_id:
			world._colonists[i]["factionId"] = expected_faction
		elif id == injured_id:
			world._colonists[i]["health"] = expected_injured_health.duplicate()
		elif id == dead_id:
			world._colonists[i]["health"] = expected_dead_health.duplicate()

	var saved := world.to_save_state()
	var restored: WorldStateType = WorldStateType.from_save_state(saved)
	for colonist in restored.get_colonists():
		var id := String(colonist["id"])
		if id == faction_id:
			_expect(String(colonist.get("factionId", "")) == expected_faction,
				"a save/load round trip must preserve a non-default factionId exactly")
		elif id == injured_id:
			_expect(colonist.get("health") == expected_injured_health,
				"a save/load round trip must preserve a non-default, non-full health snapshot exactly")
		elif id == dead_id:
			_expect(colonist.get("health") == expected_dead_health,
				"a save/load round trip must preserve a dead:true health snapshot exactly")

## Proves the v1 fixture is not just migration-shaped but an actually loadable
## save envelope: SaveIO.read() must independently verify its integrity hash,
## migrate it through the full v1->v2->v3->v4->v5->v6->v7 chain, and pass the
## current schema's _validate_state before handing back schemaVersion 7.
func _check_v1_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V1)
	_expect(result["ok"], "v1 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v1 fixture must report the current schemaVersion")
	_expect(state["items"]["list"] == [], "SaveIO-loaded v1 fixture must carry empty items")
	_expect(state["objects"] == [], "SaveIO-loaded v1 fixture must carry empty objects")
	_expect(state["zones"] == [], "SaveIO-loaded v1 fixture must carry empty zones")
	_expect(state["nextZoneId"] == 1, "SaveIO-loaded v1 fixture must carry a fresh nextZoneId")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v1 fixture must carry empty groundBerries")

## Proves the v2 fixture is an actually loadable save envelope, not just a
## dictionary shape the migration accepts directly: SaveIO.read() must verify
## its integrity hash against the real SHA-256 of its state, migrate it to
## schemaVersion 7, and pass the current schema's _validate_state.
func _check_v2_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V2)
	_expect(result["ok"], "v2 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v2 fixture must report the current schemaVersion")
	_expect(state["items"]["list"] == [], "SaveIO-loaded v2 fixture must carry empty items")
	_expect(state["objects"] == [], "SaveIO-loaded v2 fixture must carry empty objects")
	_expect(state["zones"] == [], "SaveIO-loaded v2 fixture must carry empty zones")
	_expect(state["nextZoneId"] == 1, "SaveIO-loaded v2 fixture must carry a fresh nextZoneId")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v2 fixture must carry empty groundBerries")
	for entity in state["entities"]:
		_expect(entity["route"] == null and entity["work"] == null and (entity["hands"] as Array).is_empty(),
			"SaveIO-loaded v2 fixture entities must carry null route/work and empty hands")
	var assignments: Dictionary = state["scheduling"]["assignments"]
	for worker in assignments.keys():
		_expect(assignments[worker]["path"] == [],
			"SaveIO-loaded v2 fixture assignment must be backfilled with an empty path")

## Proves the v3 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 7, and pass the
## current schema's _validate_state.
func _check_v3_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V3)
	_expect(result["ok"], "v3 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v3 fixture must report the current schemaVersion")
	_expect(state["objects"] == [], "SaveIO-loaded v3 fixture must carry empty objects")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v3 fixture must carry empty groundBerries")

## Proves the v4 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 7, and pass
## the current schema's _validate_state -- including its non-null route,
## which must still satisfy save_io.gd's own route field allow-list since
## migration never adds the optional "rerouting" key to an already-normal
## route (see StateCodec._encode_route_field()).
func _check_v4_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V4)
	_expect(result["ok"], "v4 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v4 fixture must report the current schemaVersion")
	var route: Dictionary = state["entities"][0]["route"]
	_expect(route["jobId"] == "job-7", "SaveIO-loaded v4 fixture must preserve its colonist's route")
	_expect((state["entities"][0]["hands"] as Array).is_empty(), "SaveIO-loaded v4 fixture colonist must carry nothing")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v4 fixture must carry empty groundBerries")

## Proves the v5 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate its groundItems to schemaVersion 6's
## first-class items, and pass the current schema's _validate_state.
func _check_v5_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V5)
	_expect(result["ok"], "v5 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v5 fixture must report the current schemaVersion")
	_expect(state["items"]["list"].size() == 4, "SaveIO-loaded v5 fixture must carry 4 migrated wood items")
	_expect((state["entities"][0]["hands"] as Array).is_empty(), "SaveIO-loaded v5 fixture colonist must carry nothing")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v5 fixture must carry empty groundBerries")

## Proves the v6 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 7, and pass
## the current schema's _validate_state -- including its backfilled, honestly
## empty zones list and fresh nextZoneId.
func _check_v6_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V6)
	_expect(result["ok"], "v6 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v6 fixture must report the current schemaVersion")
	_expect(state["zones"] == [], "SaveIO-loaded v6 fixture must carry an empty zones list")
	_expect(state["nextZoneId"] == 1, "SaveIO-loaded v6 fixture must carry a fresh nextZoneId")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v6 fixture must carry empty groundBerries")

## Proves the v7 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 8, and pass
## the current schema's _validate_state -- including its pre-haul job
## backfilled with the new required itemId/cell/retryAt/backoffTicks fields.
func _check_v7_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V7)
	_expect(result["ok"], "v7 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v7 fixture must report the current schemaVersion")
	_expect(state["jobs"].size() == 1, "SaveIO-loaded v7 fixture must keep its one job")
	var job: Dictionary = state["jobs"][0]
	_expect(job["itemId"] == "" and job["cell"] == null and job["retryAt"] == 0 and job["backoffTicks"] == 0,
		"SaveIO-loaded v7 fixture's job must carry backfilled haul defaults")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v7 fixture must carry empty groundBerries")

## Proves the v8 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 13, and pass
## the current schema's _validate_state -- including its colonists' backfilled
## full food/water/rest needs.
func _check_v8_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V8)
	_expect(result["ok"], "v8 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v8 fixture must report the current schemaVersion")
	for entity in state["entities"]:
		_expect(entity["needs"] == {"food": 100, "water": 100, "rest": 100},
			"SaveIO-loaded v8 fixture colonist must carry full food/water/rest needs")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v8 fixture must carry empty groundBerries")

## Proves the v9 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 13, and pass
## the current schema's _validate_state -- including its backfilled, honestly
## empty groundBerries list.
func _check_v9_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V9)
	_expect(result["ok"], "v9 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v9 fixture must report the current schemaVersion")
	_expect(state["groundBerries"] == [], "SaveIO-loaded v9 fixture must carry an empty groundBerries list")

## Proves the v10 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 13, and pass
## the current schema's _validate_state -- including its backfilled, honestly
## empty workProgress/pausedJobs/toolItems/toolReservations collections.
func _check_v10_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V10)
	_expect(result["ok"], "v10 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v10 fixture must report the current schemaVersion")
	_expect(state["workProgress"] == [], "SaveIO-loaded v10 fixture must carry an empty workProgress list")
	_expect(state["pausedJobs"] == [], "SaveIO-loaded v10 fixture must carry an empty pausedJobs list")
	_expect(state["toolItems"] == {"nextId": 1, "list": []}, "SaveIO-loaded v10 fixture must carry empty toolItems")
	_expect(state["toolReservations"] == {}, "SaveIO-loaded v10 fixture must carry empty toolReservations")

## Proves the v11 fixture is an actually loadable save envelope: SaveIO.read()
## must verify its integrity hash, migrate it to schemaVersion 13, and pass
## the current schema's _validate_state -- including its colonists' backfilled
## default all-3 labour table and its backfilled, honestly empty
## toolItems/toolReservations collections.
func _check_v11_fixture_loads_through_save_io() -> void:
	var result := SaveIOType.read(FIXTURE_V11)
	_expect(result["ok"], "v11 fixture must load through SaveIO.read(): %s" % result)
	if not result["ok"]:
		return
	var state: Dictionary = result["state"]
	_expect(state["schemaVersion"] == StateCodecType.SCHEMA_VERSION, "SaveIO-loaded v11 fixture must report the current schemaVersion")
	var default_labour_table := {"mine": 3, "chop": 3, "farm": 3, "haul": 3, "build": 3, "craft": 3, "cook": 3}
	for entity in state["entities"]:
		_expect(entity["labourTable"] == default_labour_table,
			"SaveIO-loaded v11 fixture colonist must carry the default all-3 labour table")
	_expect(state["toolItems"] == {"nextId": 1, "list": []}, "SaveIO-loaded v11 fixture must carry empty toolItems")
	_expect(state["toolReservations"] == {}, "SaveIO-loaded v11 fixture must carry empty toolReservations")

## A malformed-but-otherwise-v1-shaped save (entities is not an array of
## objects) must be rejected explicitly, not crash inside _migrate_v2_to_v3's
## later `as Dictionary` casts once it reaches the v2 stage of the chain.
func _check_malformed_v1_entities_are_rejected() -> void:
	var state := {
		"schemaVersion": 1, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"]},
		"entities": ["not-an-object"],
		"inventory": {}, "jobs": [],
	}
	var result := SaveMigrationsType.migrate(state, 1, 3)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v1 entities must be rejected, not crash: %s" % result)

## A malformed-but-otherwise-v2-shaped save (an entity is not an object) must
## be rejected before _migrate_v2_to_v3 dereferences it as a Dictionary.
func _check_malformed_v2_entities_are_rejected() -> void:
	var state := {
		"schemaVersion": 2, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"]},
		"entities": [42],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {},
		},
		"rng": {"seed": 1, "state": 0},
	}
	var result := SaveMigrationsType.migrate(state, 2, 3)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v2 entities must be rejected, not crash: %s" % result)

## A malformed-but-otherwise-v2-shaped save (an assignments entry is not an
## object) must be rejected before _migrate_v2_to_v3 dereferences it as a
## Dictionary while backfilling `path`.
func _check_malformed_v2_assignments_are_rejected() -> void:
	var state := {
		"schemaVersion": 2, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"]},
		"entities": [],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {"colonist_0": "not-an-object"},
		},
		"rng": {"seed": 1, "state": 0},
	}
	var result := SaveMigrationsType.migrate(state, 2, 3)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v2 assignments must be rejected, not crash: %s" % result)

func _minimal_v5_state() -> Dictionary:
	return {
		"schemaVersion": 5, "contentVersion": "vertical-slice-1", "seed": 1, "tick": 0,
		"map": {"width": 1, "height": 1, "tiles": ["soil"]},
		"entities": [],
		"inventory": {}, "jobs": [],
		"scheduling": {
			"nextJobId": 1, "jobSequence": 0, "jobTick": 0, "queueEventSequence": -1,
			"eventSequence": 0, "waiting": [], "nextOrdinal": 0, "cursors": {}, "pending": {},
			"assignments": {},
		},
		"rng": {"seed": 1, "state": 0},
		"groundItems": [],
		"objects": [],
	}

## A malformed-but-otherwise-v5-shaped save (a groundItems target missing "y")
## must be rejected explicitly, not silently coerced into a (0,0) item by
## _migrate_v5_to_v6's later `target["y"]` lookups.
func _check_malformed_v5_ground_item_target_is_rejected() -> void:
	var state := _minimal_v5_state()
	state["groundItems"] = [{"target": {"x": 1}, "wood": 2}]
	var result := SaveMigrationsType.migrate(state, 5, 6)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v5 groundItems target must be rejected, not coerced: %s" % result)

## A malformed-but-otherwise-v5-shaped save (a negative wood count) must be
## rejected explicitly, not silently dropped by _migrate_v5_to_v6's
## `range(wood)` loop producing zero items.
func _check_malformed_v5_negative_wood_is_rejected() -> void:
	var state := _minimal_v5_state()
	state["groundItems"] = [{"target": {"x": 1, "y": 1}, "wood": -3}]
	var result := SaveMigrationsType.migrate(state, 5, 6)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"malformed v5 negative wood must be rejected, not silently dropped: %s" % result)

func _check_entities_carry_null_route_and_work(entities: Array, raw_entities: Array) -> void:
	_expect(entities.size() == raw_entities.size(), "migration must preserve entity count")
	for i in entities.size():
		var migrated_entity: Dictionary = entities[i]
		var raw_entity: Dictionary = raw_entities[i]
		_expect(migrated_entity["id"] == raw_entity["id"] and migrated_entity["kind"] == raw_entity["kind"]
			and migrated_entity["x"] == raw_entity["x"] and migrated_entity["y"] == raw_entity["y"],
			"migration must preserve entity core fields")
		_expect(migrated_entity["route"] == null and migrated_entity["work"] == null,
			"migrated entity must carry null route and work")

func _check_entities_carry_null_carrying(entities: Array) -> void:
	for entity in entities:
		_expect((entity as Dictionary).get("carrying") == null,
			"migrated entity must carry null carrying (version 5 predates it)")

func _check_unrecognized_version() -> void:
	var result := SaveMigrationsType.migrate({"schemaVersion": 0}, 0, 3)
	_expect(not result["ok"] and result["code"] == "no_migration_available",
		"unrecognized older versions must report no_migration_available")

func _expect(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		_failed = true
