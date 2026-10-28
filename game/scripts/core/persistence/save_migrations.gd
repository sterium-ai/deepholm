class_name SaveMigrations
extends RefCounted

## Explicit migrations for persisted state dictionaries. The schema was reset to
## v1 before release (R14, ADR 049): saves written before the reset are rejected by
## SaveIO, never migrated. Steps since the reset:
## - v1 -> v2 (A5, ADR 053): terminal jobs leave the save.
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
