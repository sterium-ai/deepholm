class_name ForestContent
extends RefCounted

## forests.json's cross-references (F6a, ADR 067; ContentRegistry runs it after CropContent):
## every stage and the grown tile name a tiles.json id and plant_job a jobs.json kind. The
## plant job must plant: its effects require soil, set the first stage and consume nothing
## (a sapling uses no seed). Every stage is passable (a colonist may stand on a sapling), and
## no tile is a stage of two forests or of a crop (a stage tile names its owner). Pure and
## static, like the registry's own checks.

const SOIL_TILE := "soil"

## "" when every reference resolves (or there is no forests.json); else the first failure.
static func check(raw_by_kind: Dictionary) -> String:
	if not raw_by_kind.has("forests"):
		return ""
	var passable_of: Dictionary = {}
	var tiles: Dictionary = raw_by_kind["tiles"]
	for tile: Dictionary in (tiles["tiles"] as Array):
		passable_of[tile["id"]] = tile.get("passable", false)
	var effects_of: Dictionary = {}
	var jobs: Dictionary = raw_by_kind["jobs"]
	for job: Dictionary in (jobs["jobs"] as Array):
		effects_of[job["kind"]] = job.get("effects", {})
	var stage_owner: Dictionary = {}
	if raw_by_kind.has("crops"):
		var crops: Dictionary = raw_by_kind["crops"]
		for crop: Dictionary in (crops["crops"] as Array):
			for stage: String in (crop["stages"] as Array):
				stage_owner[stage] = "crop '%s'" % crop["id"]
	var forests: Dictionary = raw_by_kind["forests"]
	for forest: Dictionary in (forests["forests"] as Array):
		var forest_id: String = forest["id"]
		var stages: Array = forest["stages"]
		for tile_id: String in stages + [forest["grown_tile"]]:
			if not passable_of.has(tile_id):
				return "forest '%s' names an unknown tiles id '%s'" % [forest_id, tile_id]
		if not effects_of.has(forest["plant_job"]):
			return "forest '%s' names an unknown jobs id '%s'" % [forest_id, forest["plant_job"]]
		for stage: String in stages:
			if not passable_of[stage]:
				return "forest '%s' stage tile '%s' must be passable" % [forest_id, stage]
			if stage_owner.has(stage):
				return "forest '%s' reuses stage tile '%s' of %s" % [forest_id, stage, stage_owner[stage]]
			stage_owner[stage] = "forest '%s'" % forest_id
		var plant: Dictionary = effects_of[forest["plant_job"]]
		if plant.get("requires_tile", "") != SOIL_TILE or plant.get("set_tile", "") != stages[0] or plant.has("consumes"):
			return "forest '%s' plant_job '%s' must require tile '%s', set_tile '%s' and consume nothing" % [forest_id, forest["plant_job"], SOIL_TILE, stages[0]]
	return ""
