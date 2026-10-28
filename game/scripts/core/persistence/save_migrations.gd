class_name SaveMigrations
extends RefCounted

## Explicit migrations for persisted state dictionaries. The schema was reset to
## v1 before release (R14, ADR 049): the chain is empty, and saves written before
## the reset are rejected by SaveIO, never migrated. The mechanism stays for the
## first post-release change.
##
## Adding schema version N+1: bump StateCodec.SCHEMA_VERSION, add a `N:` arm to
## _migrate_step() that checks the vN shape and returns a new dictionary (never
## mutating its argument), add tests/fixtures/save_schema_vN+1_fixture.json, and a
## test that the vN fixture loads through SaveIO.read() as vN+1.

## Chains single-version steps so a save from any older version reaches to_version
## through every intermediate schema; SaveIO.read() calls
## migrate(state, version, SCHEMA_VERSION) unchanged as versions are added.
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
static func _migrate_step(_state: Dictionary, from_version: int) -> Dictionary:
	match from_version:
		_:
			return {
				"ok": false,
				"code": "no_migration_available",
				"message": "no migration is available for this save schema",
			}

# --- content-version renames ---------------------------------------------

## Content renames, keyed by the exact stored contentVersion a save was written
## under (foundation-for-breadth.md F1: "a content version goes into every save
## ... with a migration hook for content renames"). A remap is a
## Callable(state: Dictionary) -> Dictionary returning a new state with every
## renamed content id remapped, never mutating its argument. None is registered
## today: every v1 save carries the current content version.
static var _content_renames: Dictionary = {}

## Registers the remap for saves written under from_content_version.
static func register_content_rename(from_content_version: String, remap: Callable) -> void:
	_content_renames[from_content_version] = remap

## Removes exactly one registered entry, leaving every other registration untouched.
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
