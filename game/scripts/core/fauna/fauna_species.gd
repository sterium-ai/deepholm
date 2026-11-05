class_name FaunaSpecies
extends RefCounted

## species.json (F6b-1, ADR 070) resolved into tick units, plus the cross-references the schema
## subset cannot express: diet shape, prey ids, food tile ids and mapgen.json "animal_counts".
## Static; build() never mutates the document.

## The resolved table: {"ok", "message", "species": {id: record}, "order": [ids], "grass": {tile: true},
## "crops": {tile: true}}. A record holds the tick-unit fields FaunaSystem reads.
static func build(document: Dictionary, counts: Dictionary, day_ticks: int, registry: ContentRegistry) -> Dictionary:
	var grass_ids: Array = document.get("grass_tiles", [])
	var crop_ids: Array = document.get("crop_tiles", [])
	var species: Dictionary = {}
	var order: Array[String] = []
	var table := {"ok": true, "message": "", "species": species, "order": order, "grass": _tile_set(grass_ids),
		"crops": _tile_set(crop_ids)}
	for tile_id: String in (table["grass"] as Dictionary).keys() + (table["crops"] as Dictionary).keys():
		if registry != null and (registry.get_entry("tiles", tile_id) as Dictionary).is_empty():
			return _fail("species.json: unknown tile '%s'" % tile_id)
	var entries: Array = document.get("species", [])
	for entry: Dictionary in entries:
		var id: String = entry["id"]
		if species.has(id):
			return _fail("species.json: duplicate species '%s'" % id)
		species[id] = _record(entry, day_ticks)
		order.append(id)
	for id: String in order:
		var message := _check_diet(id, species[id] as Dictionary, species)
		if message != "":
			return _fail(message)
	for id: String in counts.keys():
		if not species.has(id):
			return _fail("mapgen.json animal_counts: unknown species '%s'" % id)
		var count: Variant = counts[id]
		if not (count is int) and not (count is float and is_equal_approx(count as float, roundf(count as float))):
			return _fail("mapgen.json animal_counts.%s: expected an integer" % id)
		if int(count as float) < 0:
			return _fail("mapgen.json animal_counts.%s: must be at least 0" % id)
	return table

static func _record(entry: Dictionary, day_ticks: int) -> Dictionary:
	var diet: Dictionary = entry["diet"]
	var reproduction: Dictionary = entry["reproduction"]
	return {
		"predator": diet["kind"] == "predator",
		"eats": diet.get("eats", []),
		"prey": diet.get("prey", []),
		"step_ticks": maxi(1, floori(float(day_ticks) / (entry["steps_per_day"] as float))),
		"hungry_ticks": _ticks(entry["hungry_after_days"], day_ticks),
		"starve_ticks": _ticks(entry["starve_days"], day_ticks),
		"adult_ticks": _ticks(entry["adult_days"], day_ticks),
		"birth_ticks": _ticks(reproduction["interval_days"], day_ticks),
		"radius": int(reproduction["radius"] as float),
		"cap": int(entry["cap"] as float),
		"sight": int(entry["sight"] as float),
		"health": int(entry["health"] as float),
		"attack": int(entry["attack"] as float),
	}

## A grazer names foods and no prey; a predator names prey species and no foods.
static func _check_diet(id: String, record: Dictionary, species: Dictionary) -> String:
	if record["predator"]:
		if (record["eats"] as Array).size() > 0 or (record["prey"] as Array).is_empty():
			return "species.json %s: a predator lists prey and no eats" % id
		for prey_id: String in record["prey"]:
			if not species.has(prey_id) or prey_id == id:
				return "species.json %s: unknown prey '%s'" % [id, prey_id]
	elif (record["prey"] as Array).size() > 0 or (record["eats"] as Array).is_empty():
		return "species.json %s: a grazer lists eats and no prey" % id
	return ""

static func _ticks(days: Variant, day_ticks: int) -> int:
	return int(roundf((days as float) * day_ticks))

static func _tile_set(ids: Array) -> Dictionary:
	var tiles := {}
	for tile_id: String in ids:
		tiles[tile_id] = true
	return tiles

static func _fail(message: String) -> Dictionary:
	return {"ok": false, "message": message, "species": {}, "order": [], "grass": {}, "crops": {}}
