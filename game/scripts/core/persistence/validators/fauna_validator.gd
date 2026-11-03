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

## Review round 2: a save with animal entities must carry "fauna", and its nextAnimalId must be past
## every saved animal_N, or the next birth would reuse a live id. Runs after both are validated.
static func _valid_fauna_for_animals(fauna: Variant, entities: Array) -> Dictionary:
	var highest := -1
	for entity: Variant in entities:
		if entity is Dictionary and (entity as Dictionary).get("kind") == "animal":
			highest = maxi(highest, _animal_id_number((entity as Dictionary)["id"]))
	if highest < 0:
		return {"ok": true}
	if not (fauna is Dictionary):
		return _fail("missing fauna field with animal entities present")
	if ((fauna as Dictionary)["nextAnimalId"] as int) <= highest:
		return _fail("invalid fauna.nextAnimalId: must exceed every animal id (highest animal_%d)" % highest)
	return {"ok": true}

## N of "animal_N" (digits only, game-state.schema.json's ^animal_[0-9]+$), or -1 for any other value.
static func _animal_id_number(value: Variant) -> int:
	if not (value is String) or not (value as String).begins_with("animal_"):
		return -1
	var digits := (value as String).substr(7)
	if digits.is_empty() or digits.length() > 18:
		return -1
	for i in digits.length():
		var c := digits.unicode_at(i)
		if c < 48 or c > 57:
			return -1
	return digits.to_int()
