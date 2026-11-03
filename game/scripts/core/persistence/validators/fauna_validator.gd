class_name FaunaValidator
extends SaveCheck

## Save validation for the optional "fauna" field (F6b-1, ADR 070): the next animal id and the fauna
## stream. The animals themselves are entities of kind "animal" (EntityValidator checks them,
## species against the session's species.json ids); this field carries no roster.

const FAUNA_FIELDS := ["nextAnimalId", "rng"]

static func _valid_fauna(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid fauna type")
	var fauna: Dictionary = value
	var check := _require_fields(fauna, FAUNA_FIELDS, "fauna")
	if not check["ok"]:
		return check
	if not _keys_allowed(fauna, FAUNA_FIELDS) or not (fauna["nextAnimalId"] is int and (fauna["nextAnimalId"] as int) >= 0):
		return _fail("invalid fauna fields")
	if not (fauna["rng"] is Dictionary):
		return _fail("invalid fauna.rng fields")
	var rng: Dictionary = fauna["rng"]
	if not _require_fields(rng, ["seed", "state"], "fauna.rng")["ok"] or not (rng["seed"] is int) or not (rng["state"] is int):
		return _fail("invalid fauna.rng fields")
	return {"ok": true}
