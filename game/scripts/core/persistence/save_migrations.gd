class_name SaveMigrations
extends RefCounted

## Explicit migrations for persisted state dictionaries. The schema was reset to
## v1 before release (R14, ADR 049): saves written before the reset are rejected by
## SaveIO, never migrated. Steps since the reset:
## - v1 -> v2 (A5, ADR 053): terminal jobs leave the save.
## - v2 -> v3 (A13b, ADR 010 amendment 2): the save records its content packs.
## - v3 -> v4 (A16b, ADR 057): the scenario calendar and incident list are saved.
## - v4 -> v5 (A7, ADR 058): compact file encoding (SaveWire) and saved route-search costs.
## - v5 -> v6 (F1, ADR 059): farm zones and the "crops" growth records.
##
## Adding schema version N+1: bump StateCodec.SCHEMA_VERSION, add a `N:` arm to
## _migrate_step() that checks the vN shape and returns a new dictionary (never
## mutating its argument), add tests/fixtures/save_schema_vN+1_fixture.json, and a
## test that the vN fixture loads through SaveIO.read() as vN+1.

## Chains single-version steps through every intermediate schema up to to_version.
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

## One arm per from_version, each returning {"ok": true, "state": <vN+1 state>}.
static func _migrate_step(state: Dictionary, from_version: int) -> Dictionary:
	match from_version:
		1:
			return _v1_to_v2(state)
		2:
			return _v2_to_v3(state)
		3:
			return _v3_to_v4(state)
		4:
			return _v4_to_v5(state)
		5:
			return _v5_to_v6(state)
		_:
			return {
				"ok": false,
				"code": "no_migration_available",
				"message": "no migration is available for this save schema",
			}

## v1 -> v2 (A5, ADR 053): drops completed/failed/cancelled jobs (JobQueue keeps them only in
## its unsaved history); nothing else in a v1 save names one. Non-job entries are left for the
## validator to reject.
static func _v1_to_v2(state: Dictionary) -> Dictionary:
	if not (state.get("jobs") is Array):
		return {"ok": false, "code": "schema_error", "message": "v1 save has no jobs array"}
	var migrated := state.duplicate(true)
	var live: Array = []
	for job: Variant in migrated["jobs"]:
		if job is Dictionary and (job as Dictionary).get("status") in ["completed", "failed", "cancelled"]:
			continue
		live.append(job)
	migrated["jobs"] = live
	migrated["schemaVersion"] = 2
	return {"ok": true, "state": migrated}

## v2 -> v3 (A13b, ADR 010 amendment 2): adds "contentPacks" right after "contentVersion" (the
## order encode() writes). boot.gd applied no pack roots before v3 (CONTENT_PACK_ROOTS was
## empty), so every v2 save was made on the base bundle alone: the list is empty.
static func _v2_to_v3(state: Dictionary) -> Dictionary:
	if state.has("contentPacks"):
		return {"ok": false, "code": "schema_error", "message": "v2 save already has contentPacks"}
	var migrated: Dictionary = {}
	for key: Variant in state.keys():
		migrated[key] = state[key]
		if key == "contentVersion":
			migrated["contentPacks"] = []
	if not migrated.has("contentPacks"):
		migrated["contentPacks"] = []
	migrated = migrated.duplicate(true)
	migrated["schemaVersion"] = 3
	return {"ok": true, "state": migrated}

## v3 -> v4 (A16b, ADR 057): adds "scenarioStart" as the base start, {"calendar": null,
## "enabledIncidents": []}: a v3 world always ran on calendar.json and every incident, and so
## does the migrated one. Nothing else changes.
static func _v3_to_v4(state: Dictionary) -> Dictionary:
	if state.has("scenarioStart"):
		return {"ok": false, "code": "schema_error", "message": "v3 save already has scenarioStart"}
	var migrated := state.duplicate(true)
	migrated["scenarioStart"] = {"calendar": null, "enabledIncidents": []}
	migrated["schemaVersion"] = 4
	return {"ok": true, "state": migrated}

## v4 -> v5 (A7, ADR 058): SaveIO already unpacked the file (SaveWire.unpack() leaves a v4
## file's plain map and routes alone), so the state keeps its shape. A v4 route search has no
## "cost": it stays absent, and RouteSearch.restore() rebuilds the costs from the current map,
## exactly as every v4 load did. Nothing else differs.
static func _v4_to_v5(state: Dictionary) -> Dictionary:
	if not (state.get("map") is Dictionary) or not (state["map"] as Dictionary).has("tiles"):
		return {"ok": false, "code": "schema_error", "message": "v4 save has no map tiles"}
	var migrated := state.duplicate(true)
	migrated["schemaVersion"] = 5
	return {"ok": true, "state": migrated}

## v5 -> v6 (F1, ADR 059): adds an empty "crops" list. Every v5 zone is a stockpile (no "kind"),
## which is v6's stockpile shape; a v5 sown tile gets its growth record from
## FarmSystem.decode()'s reconcile, starting at its stage's threshold.
static func _v5_to_v6(state: Dictionary) -> Dictionary:
	if state.has("crops"):
		return {"ok": false, "code": "schema_error", "message": "v5 save already has crops"}
	var migrated := state.duplicate(true)
	migrated["crops"] = []
	migrated["schemaVersion"] = 6
	return {"ok": true, "state": migrated}

# --- content-version renames ---------------------------------------------

## Content renames keyed by the exact stored contentVersion (F1's content-rename hook); each
## remap returns a new state and never mutates its argument. None is registered today.
static var _content_renames: Dictionary = {}

## Registers the remap for saves written under from_content_version.
static func register_content_rename(from_content_version: String, remap: Callable) -> void:
	_content_renames[from_content_version] = remap

## Removes exactly one registered entry, leaving every other registration untouched.
static func unregister_content_rename(from_content_version: String) -> void:
	_content_renames.erase(from_content_version)

## {"ok": false} when no rename matches (SaveIO reports content_version_mismatch); on success
## the returned state already carries to_content_version.
static func resolve_content_version(state: Dictionary, to_content_version: String) -> Dictionary:
	var from_content_version := String(state.get("contentVersion", ""))
	if not _content_renames.has(from_content_version):
		return {"ok": false}
	var remap: Callable = _content_renames[from_content_version]
	var resolved: Dictionary = (remap.call(state) as Dictionary).duplicate(true)
	resolved["contentVersion"] = to_content_version
	return {"ok": true, "state": resolved}
