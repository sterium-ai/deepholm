class_name FaunaValidator
extends SaveCheck

## Save validation for the optional "fauna" field (F6b-1, ADR 070): the wild-animal roster, the
## next animal id and the fauna stream. A species must be one of the session's species.json ids
## (SaveIO.content_rules()["species"]); FaunaSystem drops nothing on load, so a bad record fails here.

const FAUNA_FIELDS := ["animals", "nextAnimalId", "rng"]
const ANIMAL_FIELDS := ["id", "kind", "species", "x", "y", "z", "factionId", "bornTick", "lastMealTick",
	"nextBirthTick", "health"]

static func _valid_fauna(value: Variant, map_width: int, map_height: int, layer_count: int, species_ids: Array[String]) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid fauna type")
	var fauna: Dictionary = value
	var check := _require_fields(fauna, FAUNA_FIELDS, "fauna")
	if not check["ok"]:
		return check
	if not _keys_allowed(fauna, FAUNA_FIELDS) or not (fauna["animals"] is Array) or not (fauna["nextAnimalId"] is int and (fauna["nextAnimalId"] as int) >= 0):
		return _fail("invalid fauna fields")
	if not (fauna["rng"] is Dictionary):
		return _fail("invalid fauna.rng fields")
	var rng: Dictionary = fauna["rng"]
	if not _require_fields(rng, ["seed", "state"], "fauna.rng")["ok"] or not (rng["seed"] is int) or not (rng["state"] is int):
		return _fail("invalid fauna.rng fields")
	var seen_ids := {}
	for animal: Variant in (fauna["animals"] as Array):
		var animal_check := _valid_animal(animal, map_width, map_height, layer_count, species_ids)
		if not animal_check["ok"]:
			return animal_check
		var id: String = (animal as Dictionary)["id"]
		if seen_ids.has(id):
			return _fail("duplicate fauna animal id '%s'" % id)
		seen_ids[id] = true
	return {"ok": true}

static func _valid_animal(value: Variant, map_width: int, map_height: int, layer_count: int, species_ids: Array[String]) -> Dictionary:
	if not (value is Dictionary):
		return _fail("invalid fauna animal type")
	var animal: Dictionary = value
	var check := _require_fields(animal, ANIMAL_FIELDS, "fauna animal")
	if not check["ok"]:
		return check
	if not _keys_allowed(animal, ANIMAL_FIELDS) or animal["kind"] != "animal" or not (animal["species"] is String) or not species_ids.has(animal["species"] as String) \
			or not (animal["id"] is String) or not (animal["id"] as String).begins_with("animal_") \
			or not (animal["factionId"] is String) or not (animal["health"] is int and (animal["health"] as int) >= 0):
		return _fail("invalid fauna animal fields")
	for field: String in ["bornTick", "lastMealTick", "nextBirthTick"]:
		if not (animal[field] is int):
			return _fail("invalid fauna animal %s" % field)
	# _valid_tile() takes exactly {x, y, z}, so the flat record's coordinates go in alone.
	return _valid_tile({"x": animal["x"], "y": animal["y"], "z": animal["z"]}, map_width, map_height, layer_count)
